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

  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
  alias PhoenixKit.Modules.Emails.EventTrackerRegistry

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:rows, build_rows())
      |> assign_new(:busy, fn -> %{} end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_tracking", %{"provider" => provider_kind}, socket) do
    tracker = fetch_tracker!(provider_kind)

    result =
      if tracker.enabled?(), do: tracker.disable_polling(), else: tracker.enable_polling()

    socket =
      case success?(result) do
        true ->
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

    {:noreply, socket}
  end

  def handle_event("poll_now", %{"provider" => provider_kind}, socket) do
    tracker = fetch_tracker!(provider_kind)
    socket = put_busy(socket, provider_kind, true)

    result = tracker.poll_now()

    socket =
      socket
      |> put_busy(provider_kind, false)
      |> assign(:rows, build_rows())

    socket =
      case result do
        {:ok, _job} ->
          put_flash(socket, :info, gettext("%{label} poll triggered", label: tracker.label()))

        {:error, _reason} ->
          put_flash(
            socket,
            :error,
            gettext("Failed to trigger %{label} poll", label: tracker.label())
          )
      end

    {:noreply, socket}
  end

  def handle_event("restart", %{"provider" => provider_kind}, socket) do
    tracker = fetch_tracker!(provider_kind)

    socket =
      case EventTrackerReconciler.reconcile_tracker(tracker) do
        {:ok, _} ->
          socket
          |> assign(:rows, build_rows())
          |> put_flash(:info, gettext("%{label} restarted", label: tracker.label()))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Failed to restart %{label}", label: tracker.label()))
      end

    {:noreply, socket}
  end

  def handle_event("update_interval", %{"provider" => provider_kind} = params, socket) do
    tracker = fetch_tracker!(provider_kind)
    value = Map.get(params, "interval") || Map.get(params, "value")

    socket =
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
                gettext("Failed to update interval: %{reason}", reason: inspect(reason))
              )
          end

        :error ->
          put_flash(socket, :error, gettext("Please enter a valid number of milliseconds"))
      end

    {:noreply, socket}
  end

  def handle_event("toggle_account", %{"provider" => provider_kind, "uuid" => uuid}, socket) do
    tracker = fetch_tracker!(provider_kind)

    socket =
      case tracker.toggle_account_polling(uuid) do
        {:ok, _setting} ->
          assign(socket, :rows, build_rows())

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Failed to update account polling"))
      end

    {:noreply, socket}
  end

  ## --- Private ---

  defp fetch_tracker!(provider_kind) do
    Enum.find(EventTrackerRegistry.trackers(), &(&1.provider_kind() == provider_kind)) ||
      raise "no registered EventTracker for provider_kind=#{inspect(provider_kind)}"
  end

  defp success?({:ok, _}), do: true
  defp success?(:ok), do: true
  defp success?(_), do: false

  defp put_busy(socket, provider_kind, value?) do
    assign(socket, :busy, Map.put(socket.assigns.busy, provider_kind, value?))
  end

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
      integration_count: tracker.integration_count(),
      state: EventTracker.state(tracker),
      last_polled_at: EventTracker.last_polled_at(tracker),
      pending_jobs: EventTracker.pending_jobs_count(tracker),
      interval_ms: tracker.interval_ms(),
      accounts: accounts_for(tracker)
    }
  end

  defp accounts_for(tracker) do
    if function_exported?(tracker, :accounts, 0), do: tracker.accounts(), else: nil
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

  defp state_hint(:idle_no_integration),
    do: gettext("Turn it on by adding or configuring a matching integration.")

  defp state_hint(:off), do: gettext("Tracking is turned off.")

  defp state_hint(:stalled),
    do:
      gettext(
        "No cycle is currently queued — this can happen after a lost job. Restart to recover immediately; the automatic check also fixes this within a couple of minutes."
      )
end
