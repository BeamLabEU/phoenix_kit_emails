defmodule PhoenixKit.Modules.Emails.BrevoPollingManager do
  @moduledoc """
  Manager module for Brevo event polling via Oban jobs.

  Mirrors `SQSPollingManager` — see that module's `@moduledoc` for the
  general architecture (Oban jobs instead of a GenServer, so settings
  changes take effect without a restart). `enable_polling/0` and
  `disable_polling/0` back the admin UI toggle; `poll_now/0` forces an
  immediate cycle regardless of the sender-aware gate (useful to verify a
  freshly-configured Brevo profile before waiting for the next scheduled
  tick — the job itself still no-ops safely if the gate isn't satisfied).
  """

  @behaviour PhoenixKit.Modules.Emails.EventTracker

  require Logger

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoIntegrations
  alias PhoenixKit.Modules.Emails.BrevoPollingJob

  ## --- EventTracker behaviour ---
  #
  # Thin wrappers over the existing BrevoPollingJob/Manager logic — see
  # PhoenixKit.Modules.Emails.EventTracker's moduledoc for the full
  # eligible?/enabled? split rationale. Unlike SES, Brevo has no separate
  # feature/eligibility key — an active brevo_api SendProfile IS
  # eligibility (BrevoIntegrations.active_integration_uuids/0's own
  # definition, already the sender-aware gate used elsewhere in this
  # module).

  @impl PhoenixKit.Modules.Emails.EventTracker
  def provider_kind, do: "brevo_api"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def label, do: "Brevo"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def eligible?, do: Emails.enabled?() and BrevoIntegrations.active_integration_uuids() != []

  @impl PhoenixKit.Modules.Emails.EventTracker
  def enabled?, do: Emails.brevo_events_enabled?()

  @impl PhoenixKit.Modules.Emails.EventTracker
  def poll_cycle(_context), do: BrevoPollingJob.perform(%Oban.Job{})

  @impl PhoenixKit.Modules.Emails.EventTracker
  def interval_ms, do: Emails.get_brevo_polling_interval()

  # Matches set_polling_interval/1's own guard below — single source of
  # truth would be nicer, but the guard needs a literal for the function
  # clause match; kept in sync by hand (both change together, rarely).
  @impl PhoenixKit.Modules.Emails.EventTracker
  def min_interval_ms, do: 30_000

  @impl PhoenixKit.Modules.Emails.EventTracker
  def worker, do: BrevoPollingJob

  ## --- Optional EventTracker callbacks (Accounts column) ---
  #
  # integration_count/0, accounts/0, toggle_account_polling/1 are formal
  # @optional_callbacks on EventTracker (task #56 P2 review) — the panel
  # never calls these three directly on a tracker module, always through
  # EventTracker.integration_count/1, accounts/1, toggle_account_polling/2,
  # which supply a safe default/no-op for a tracker that skips them. This
  # module defines all three because Brevo has a genuine multi-account
  # opt-out concept.

  # Number of distinct active brevo_api integrations — the admin panel's
  # "N active accounts" Integration-column count.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def integration_count, do: length(BrevoIntegrations.active_integration_uuids())

  # Per-integration opt-out list for the admin panel's Accounts column:
  # {uuid, name, polled?} for every currently-active Brevo account.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def accounts do
    excluded = MapSet.new(Emails.get_brevo_polling_excluded_integrations())

    BrevoIntegrations.active_integrations_with_names()
    |> Enum.map(fn {uuid, name} -> {uuid, name, not MapSet.member?(excluded, uuid)} end)
  end

  # Flips one integration's polling opt-out (see accounts/0). A uuid
  # that isn't a currently-active brevo_api integration (stale, already
  # removed, or simply forged in a phx-click) is ignored rather than
  # written into the exclusion setting — that list should only ever
  # contain uuids accounts/0 could plausibly have shown a checkbox for.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def toggle_account_polling(uuid) do
    if uuid in BrevoIntegrations.active_integration_uuids() do
      excluded = Emails.get_brevo_polling_excluded_integrations()

      new_excluded =
        if uuid in excluded, do: List.delete(excluded, uuid), else: [uuid | excluded]

      Emails.set_brevo_polling_excluded_integrations(new_excluded)
    else
      {:ok, :ignored}
    end
  end

  @doc """
  Enables Brevo event polling by setting the configuration and starting
  the first job.
  """
  def enable_polling do
    Logger.info("Brevo Polling Manager: Enabling polling")

    with {:ok, _setting} <- Emails.set_brevo_events_enabled(true),
         {:ok, job} <- insert_poll_job() do
      Logger.info("Brevo Polling Manager: Polling enabled and first job started")
      {:ok, job}
    else
      {:error, reason} = error ->
        Logger.error("Brevo Polling Manager: Failed to enable polling", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Disables Brevo event polling by updating the configuration.

  No explicit job cancellation: `BrevoPollingJob.perform/1` checks
  `should_poll?/0` (unless forced) before self-scheduling its next cycle
  — see that module. At most one already-queued job fires once more,
  sees polling disabled, does nothing, and does not re-schedule; the
  chain dies on its own within one cycle.
  """
  def disable_polling do
    Logger.info("Brevo Polling Manager: Disabling polling")

    case Emails.set_brevo_events_enabled(false) do
      {:ok, _setting} ->
        Logger.info("Brevo Polling Manager: Polling disabled")
        :ok

      {:error, reason} ->
        Logger.error("Brevo Polling Manager: Failed to disable polling", %{
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Sets the polling interval in milliseconds (minimum 30 000ms).
  """
  def set_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms >= 30_000 do
    Logger.info("Brevo Polling Manager: Setting polling interval to #{interval_ms}ms")
    Emails.set_brevo_polling_interval(interval_ms)
  end

  def set_polling_interval(interval_ms) do
    {:error, "Invalid interval: #{interval_ms}. Must be >= 30000ms"}
  end

  @doc """
  Triggers an immediate polling job, regardless of the normal schedule
  or the `brevo_events_enabled` toggle — a `forced: true` job (see
  `BrevoPollingJob.perform/1`) still fetches once even while polling is
  disabled, rather than silently no-op'ing while claiming success. Still
  respects `Emails.enabled?/0` (system disabled) and the sender-aware
  profile gate: a forced poll with zero active Brevo profiles correctly
  fetches nothing, same as a scheduled cycle would.
  """
  def poll_now do
    Logger.info("Brevo Polling Manager: Triggering immediate poll")

    unless polling_enabled?() do
      Logger.warning(
        "Brevo Polling Manager: Polling toggle is off, forcing a one-off poll anyway"
      )
    end

    case insert_forced_poll_job() do
      {:ok, job} ->
        Logger.info("Brevo Polling Manager: Immediate poll job created", %{job_id: job.id})
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("Brevo Polling Manager: Failed to create immediate poll job", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Returns the current status of Brevo event polling.

  `active_brevo_profiles` is the sender-aware gate's own count (see
  `BrevoPollingJob`'s moduledoc): the number of *enabled* send profiles
  pointed at a `"brevo_api"` integration. When it's 0, the polling chain
  is alive (as long as `enabled` is true) but every cycle no-ops.

  `total_brevo_accounts`/`polling_brevo_accounts` are the *distinct
  integration* view the per-account opt-out list needs — several
  profiles can share one integration, so this can differ from
  `active_brevo_profiles`. `polling_brevo_accounts` excludes whatever's
  in `Emails.get_brevo_polling_excluded_integrations/0`; when it's `0`
  while `total_brevo_accounts` is not, every active account has been
  explicitly excluded.
  """
  def status do
    total_accounts = BrevoIntegrations.active_integration_uuids()
    excluded = MapSet.new(Emails.get_brevo_polling_excluded_integrations())

    %{
      enabled: Emails.brevo_events_enabled?(),
      interval_ms: Emails.get_brevo_polling_interval(),
      pending_jobs: count_pending_jobs(),
      last_polled_at: Emails.get_brevo_last_polled_at(),
      system_enabled: Emails.enabled?(),
      active_brevo_profiles: count_active_brevo_profiles(),
      total_brevo_accounts: length(total_accounts),
      polling_brevo_accounts: Enum.count(total_accounts, &(not MapSet.member?(excluded, &1)))
    }
  end

  ## --- Private Functions ---

  # Per-call unique:/replace: override, NOT the job's worker-level default
  # (:scheduled only — see SQSPollingJob's moduledoc, which this mirrors).
  # This one also covers :available, so enable_polling/0 collapses into the
  # existing next-tick job (moved to run right now via replace:) instead of
  # leaving two rows. :executing stays excluded — a job already executing
  # when this fires gets a genuinely separate immediate job, which is
  # correct here (not a bug).
  #
  # `schedule_in: 0` is explicit and load-bearing — see SQSPollingManager's
  # `insert_poll_job/0` for why: without it, the new insert's changeset has
  # no `:scheduled_at` change for `replace:` to copy, and a conflicting
  # future job would silently NOT get moved up.
  defp insert_poll_job do
    %{}
    |> BrevoPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  # `args: %{"forced" => true}` differs from the regular chain's `%{}` —
  # Oban's unique check matches on args by default, so this can only ever
  # conflict with ANOTHER forced job, never the regular chain. That's
  # deliberate: repeated poll_now/0 clicks collapse into one (moved to run
  # now via replace:), without ever touching — or cancelling — the regular
  # chain's own next scheduled tick. (The old cancel_scheduled/0-based
  # poll_now did NOT have this property: it deleted every queued job for
  # this worker regardless of args, so a poll_now click could silently wipe
  # out an already-scheduled regular cycle. This is a behavior fix, not
  # just a mechanical port.) `schedule_in: 0` — same reason as
  # `insert_poll_job/0` above.
  defp insert_forced_poll_job do
    %{"forced" => true}
    |> BrevoPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  defp polling_enabled? do
    Emails.brevo_events_enabled?()
  end

  defp count_active_brevo_profiles do
    SendProfiles.list_send_profiles()
    |> Enum.count(&(&1.enabled and &1.provider_kind == "brevo_api"))
  end

  defp count_pending_jobs do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = BrevoPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end
end
