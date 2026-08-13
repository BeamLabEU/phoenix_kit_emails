defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking do
  @moduledoc """
  "Delivery event tracking" section on the core Email Sending settings
  page (`/admin/settings/email-sending`) — the unified, registry-driven
  admin panel from the universalization spec (`dev_docs/specs/
  2026-07-26-email-event-tracking-universalization-spec.md` §5). One row
  per `EventTrackerRegistry.trackers/0` entry; a new provider (Mailgun,
  …) appears automatically once it registers, no panel code to touch.

  Replaces the polling controls that used to live in the two separate
  provider settings sections (`amazon_ses_sqs`, `brevo_events`) — see
  those modules' moduledocs for what stayed behind (transport/identity
  config, not polling).

  ## "Poll now" vs `poll_cycle/1`

  `EventTracker.poll_cycle/1`'s own moduledoc anticipated this button
  calling it directly (a synchronous, in-process cycle). This panel
  calls each tracker's `poll_now/0` instead (see `EventTrackerRegistry`'s
  duck-typed "Manager API"): it already exists, already handles the
  "force a poll even while the toggle is off" case explicitly, and
  enqueues via Oban rather than blocking the LiveView process for a
  network round trip. `poll_cycle/1` stays defined (still satisfies the
  behaviour) but unused here — a deliberate choice, not an oversight.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  require Logger

  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
  alias PhoenixKit.Modules.Emails.EventTrackerRegistry

  @impl true
  def update(assigns, socket) do
    rows = build_rows()

    socket =
      socket
      |> assign(assigns)
      |> assign(:rows, rows)
      |> assign_new(:accounts_for, fn -> nil end)
      |> keep_open_only_for_existing_row(rows)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_tracking", %{"provider" => provider_kind}, socket) do
    with_tracker(socket, provider_kind, fn tracker ->
      result =
        if tracker.enabled?(), do: tracker.disable_polling(), else: tracker.enable_polling()

      case success?(result) do
        true ->
          # The managers only write the setting — and enable_polling/0
          # additionally inserts a chain UNCONDITIONALLY, without consulting
          # eligible?/0. Toggling SES on while no queue URL is configured
          # therefore queues a chain the lifecycle invariant says must not
          # exist (the panel shows "Idle — no integration" next to a
          # non-zero Queued count), and toggling off leaves the queued job
          # behind; both only get cleaned up on the next reconcile Cron
          # tick, or never on a host that skipped wiring the Cron.
          # Reconciling here is spec §4.3's "settings toggle" trigger, the
          # caller EventTrackerReconciler's own moduledoc already names.
          EventTrackerReconciler.reconcile_tracker(tracker)

          socket
          |> assign(:rows, build_rows())
          |> put_flash(:info, gettext("%{label} tracking updated", label: tracker.label()))

        false ->
          put_flash(
            socket,
            :error,
            gettext("Failed to update %{label} tracking", label: tracker.label())
          )
      end
    end)
  end

  # poll_now/0 forces a cycle past the operator's toggle, but never past
  # eligibility — a forced job for an ineligible tracker runs, fails its
  # own `pollable_ignoring_toggle?`/profile gate, and does nothing, while
  # the flash claimed a poll was triggered. Refuse up front and say why
  # (reusing the State column's own hint for this state rather than
  # inventing a second wording for the same condition).
  def handle_event("poll_now", %{"provider" => provider_kind}, socket) do
    with_tracker(socket, provider_kind, fn tracker ->
      if tracker.eligible?() do
        case tracker.poll_now() do
          {:ok, _job} ->
            socket
            |> assign(:rows, build_rows())
            |> put_flash(:info, gettext("%{label} poll triggered", label: tracker.label()))

          {:error, _reason} ->
            put_flash(
              socket,
              :error,
              gettext("Failed to trigger %{label} poll", label: tracker.label())
            )
        end
      else
        put_flash(socket, :error, state_hint(:idle_no_integration))
      end
    end)
  end

  def handle_event("restart", %{"provider" => provider_kind}, socket) do
    with_tracker(socket, provider_kind, fn tracker ->
      case EventTrackerReconciler.reconcile_tracker(tracker) do
        {:ok, _} ->
          socket
          |> assign(:rows, build_rows())
          |> put_flash(:info, gettext("%{label} restarted", label: tracker.label()))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Failed to restart %{label}", label: tracker.label()))
      end
    end)
  end

  def handle_event("update_interval", %{"provider" => provider_kind} = params, socket) do
    with_tracker(socket, provider_kind, fn tracker ->
      value = Map.get(params, "interval") || Map.get(params, "value")

      case Integer.parse(value || "") do
        {interval_ms, _} ->
          case tracker.set_polling_interval(interval_ms) do
            {:ok, _setting} ->
              socket
              |> assign(:rows, build_rows())
              |> put_flash(
                :info,
                gettext("%{label} polling interval updated to %{ms}ms",
                  label: tracker.label(),
                  ms: interval_ms
                )
              )

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                gettext("Failed to update interval: %{reason}", reason: format_reason(reason))
              )
          end

        :error ->
          put_flash(socket, :error, gettext("Please enter a valid number of milliseconds"))
      end
    end)
  end

  def handle_event("open_accounts", %{"provider" => provider_kind}, socket) do
    # Only a provider that actually exposes an account list can open the dialog:
    # a forged phx-value would otherwise render a modal over a row that has none.
    case account_row(socket.assigns.rows, provider_kind) do
      nil -> {:noreply, socket}
      _row -> {:noreply, assign(socket, :accounts_for, provider_kind)}
    end
  end

  def handle_event("close_accounts", _params, socket) do
    {:noreply, assign(socket, :accounts_for, nil)}
  end

  def handle_event("toggle_account", %{"provider" => provider_kind, "uuid" => uuid}, socket) do
    with_tracker(socket, provider_kind, fn tracker ->
      case EventTracker.toggle_account_polling(tracker, uuid) do
        {:ok, _result} ->
          assign(socket, :rows, build_rows())

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Failed to update account polling"))
      end
    end)
  end

  @doc false
  # The row whose accounts the dialog is editing — the template reads it.
  def accounts_row(rows, provider_kind), do: account_row(rows, provider_kind)

  ## --- Private ---

  # A row that both exists and exposes an account list (`accounts` is nil for
  # single-account trackers).
  defp account_row(rows, provider_kind) do
    Enum.find(rows, fn row -> row.provider_kind == provider_kind and row.accounts != nil end)
  end

  # A dialog must never outlive the row it edits: a tracker removed by a deploy
  # (or a provider whose accounts went away) closes it instead of rendering over
  # a row that is no longer there.
  defp keep_open_only_for_existing_row(socket, rows) do
    case socket.assigns[:accounts_for] do
      nil ->
        socket

      provider_kind ->
        if account_row(rows, provider_kind),
          do: socket,
          else: assign(socket, :accounts_for, nil)
    end
  end

  # Resolves provider_kind to its registered tracker and runs fun/1
  # against it, always returning {:noreply, socket}. A provider_kind
  # with no registered tracker (a stale panel tab open across a
  # deploy that removed a tracker, or a forged phx-click) is logged and
  # otherwise ignored — a crashed LiveView is a worse failure mode than
  # a silently no-op'd click (P2 dual-review fix 5b).
  defp with_tracker(socket, provider_kind, fun) do
    case fetch_tracker(provider_kind) do
      nil ->
        Logger.warning(
          "DeliveryEventTracking: no registered EventTracker for provider_kind=#{inspect(provider_kind)}"
        )

        {:noreply, socket}

      tracker ->
        {:noreply, fun.(tracker)}
    end
  end

  defp fetch_tracker(provider_kind) do
    Enum.find(EventTrackerRegistry.trackers(), &(&1.provider_kind() == provider_kind))
  end

  defp success?({:ok, _}), do: true
  defp success?(:ok), do: true
  defp success?(_), do: false

  # Both managers' set_polling_interval/1 already return a
  # human-readable string reason ("Invalid interval: ... Must be >=
  # ...ms") — interpolating that straight into the flash used to go
  # through inspect/1, which re-quotes an already-plain string (visible
  # as literal double quotes in the rendered message). Kept as a
  # fallback, not removed outright, since a reason isn't guaranteed to
  # be a string for every conceivable future tracker.
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp build_rows do
    Enum.map(EventTrackerRegistry.trackers(), &build_row/1)
  end

  defp build_row(tracker) do
    %{
      tracker: tracker,
      provider_kind: tracker.provider_kind(),
      label: tracker.label(),
      eligible: tracker.eligible?(),
      enabled: tracker.enabled?(),
      integration_count: EventTracker.integration_count(tracker),
      state: EventTracker.state(tracker),
      last_polled_at: EventTracker.last_polled_at(tracker),
      pending_jobs: EventTracker.pending_jobs_count(tracker),
      interval_ms: tracker.interval_ms(),
      min_interval_ms: tracker.min_interval_ms(),
      accounts: EventTracker.accounts(tracker)
    }
  end

  defp integration_summary(count) when is_integer(count) and count > 0 do
    ngettext("%{count} active integration", "%{count} active integrations", count, count: count)
  end

  defp integration_summary(_count), do: gettext("No integration configured")

  defp state_badge_class(:active), do: "badge-success"
  defp state_badge_class(:idle_no_integration), do: "badge-ghost"
  defp state_badge_class(:off), do: "badge-ghost"
  defp state_badge_class(:stalled), do: "badge-warning"

  defp state_label(:active), do: gettext("Active")
  defp state_label(:idle_no_integration), do: gettext("Idle — no integration")
  defp state_label(:off), do: gettext("Off")
  defp state_label(:stalled), do: gettext("Stalled")

  defp state_hint(:active), do: gettext("Running normally.")

  # Generalized rather than per-provider (P2 dual-review NOTE 5c): "add a
  # matching integration" is literally true for Brevo, but SES's
  # eligible?/0 also folds email_ses_events + credentials, so a
  # single-provider-specific wording would be wrong for one of the two
  # trackers this already renders for.
  defp state_hint(:idle_no_integration),
    do:
      gettext(
        "Connect a matching integration and make sure any provider-specific event-tracking option (e.g. AWS SES Events) is turned on."
      )

  defp state_hint(:off), do: gettext("Tracking is turned off.")

  defp state_hint(:stalled),
    do:
      gettext(
        "No cycle is currently queued — this can happen after a lost job. Restart to recover immediately; the automatic check also fixes this within a couple of minutes."
      )
end
