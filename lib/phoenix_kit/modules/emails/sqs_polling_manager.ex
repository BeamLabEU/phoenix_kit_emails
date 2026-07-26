defmodule PhoenixKit.Modules.Emails.SQSPollingManager do
  @moduledoc """
  Manager module for SQS polling via Oban jobs.

  This module provides a unified API for managing SQS polling that can be
  enabled/disabled dynamically without application restart.

  ## Features

  - **Enable/Disable Polling**: Start or stop polling without restart
  - **Manual Triggering**: Force immediate polling when needed
  - **Status Monitoring**: Get current polling status and job information
  - **Settings Integration**: Automatically uses PhoenixKit Settings
  - **Interval Control**: Dynamically adjust polling frequency

  ## Architecture

  Instead of using a GenServer, this manager uses Oban jobs for polling:
  - Each job polls SQS once and schedules the next job
  - Jobs check settings before executing (dynamic control)
  - No need to restart GenServer when settings change

  ## Usage

      # Enable polling
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      {:ok, %Oban.Job{}}

      # Disable polling
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      :ok

      # Check status
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.status()
      %{
        enabled: true,
        interval_ms: 5000,
        pending_jobs: 1,
        last_run: ~U[2025-09-20 15:30:45Z],
        queue_url: "https://sqs.eu-north-1.amazonaws.com/..."
      }

      # Trigger immediate poll
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()
      {:ok, %Oban.Job{}}

      # Change polling interval
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.set_polling_interval(3000)
      {:ok, %Setting{}}

  ## Integration

  This manager is the single control surface for SQS polling: it drives the
  Oban `SQSPollingJob`. `enable_polling/0` and `disable_polling/0` back the
  admin UI toggle. `poll_now/0` and `set_polling_interval/1` are part of the
  public consumer API (no admin-UI caller today); they are safe to call
  directly from host applications.
  """

  @behaviour PhoenixKit.Modules.Emails.EventTracker

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob

  ## --- EventTracker behaviour ---
  #
  # Thin wrappers over the existing SQSPollingJob/Manager logic — see
  # PhoenixKit.Modules.Emails.EventTracker's moduledoc for the full
  # eligible?/enabled? split rationale.

  @impl PhoenixKit.Modules.Emails.EventTracker
  def provider_kind, do: "aws_ses"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def label, do: "Amazon SES"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def eligible?, do: SQSPollingJob.pollable_ignoring_toggle?()

  @impl PhoenixKit.Modules.Emails.EventTracker
  def enabled?, do: Emails.sqs_polling_enabled?()

  @impl PhoenixKit.Modules.Emails.EventTracker
  def poll_cycle(_context), do: SQSPollingJob.perform(%Oban.Job{})

  @impl PhoenixKit.Modules.Emails.EventTracker
  def interval_ms, do: Emails.get_sqs_config().polling_interval_ms

  @impl PhoenixKit.Modules.Emails.EventTracker
  def worker, do: SQSPollingJob

  # SES has no multi-account concept in this codebase (one "SES
  # credentials source" picker, not a list) — 1 when a working event
  # source is configured (mirrors eligible?/0), 0 otherwise. Formal
  # @optional_callback on EventTracker — see BrevoPollingManager's own
  # "Optional EventTracker callbacks" section for the full rationale
  # (SQS skips accounts/0 + toggle_account_polling/1, no opt-out concept
  # here).
  @impl PhoenixKit.Modules.Emails.EventTracker
  def integration_count, do: if(SQSPollingJob.pollable_ignoring_toggle?(), do: 1, else: 0)

  ## --- Admin panel duck-typed extras (informal, not EventTracker callbacks) ---
  #
  # enable_polling/0, disable_polling/0, poll_now/0, set_polling_interval/1,
  # status/0 below — same informal "Manager API shared shape" convention
  # spec §3 documents, not part of the formal EventTracker behaviour.

  @doc """
  Enables SQS polling by setting the configuration and starting the first job.

  ## Returns

  - `{:ok, job}` - Successfully enabled and started first job
  - `{:error, reason}` - Failed to enable polling

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      {:ok, %Oban.Job{id: 1, queue: "sqs_polling"}}
  """
  def enable_polling do
    Logger.info("SQS Polling Manager: Enabling polling")

    with {:ok, _setting} <- Emails.set_sqs_polling(true),
         {:ok, job} <- insert_poll_job() do
      Logger.info("SQS Polling Manager: Polling enabled and first job started")
      {:ok, job}
    else
      {:error, reason} = error ->
        Logger.error("SQS Polling Manager: Failed to enable polling", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Disables SQS polling by updating the configuration.

  No explicit job cancellation: `SQSPollingJob.perform/1` checks
  `should_poll?/0` before doing any work AND before self-scheduling its
  next cycle (see that module). At most one already-queued job fires
  once more, sees polling disabled, does nothing, and does not
  re-schedule — the chain dies on its own within one cycle. That one
  harmless no-op run is the accepted cost of not doing a manual DELETE
  here.

  ## Returns

  - `:ok` - Successfully disabled

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      :ok
  """
  def disable_polling do
    Logger.info("SQS Polling Manager: Disabling polling")

    case Emails.set_sqs_polling(false) do
      {:ok, _setting} ->
        Logger.info("SQS Polling Manager: Polling disabled")
        :ok

      {:error, reason} ->
        Logger.error("SQS Polling Manager: Failed to disable polling", %{
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Sets the polling interval in milliseconds.

  The new interval will be used for subsequent job scheduling.

  ## Parameters

  - `interval_ms` - Interval in milliseconds (minimum 1000ms)

  ## Returns

  - `{:ok, setting}` - Successfully updated
  - `{:error, reason}` - Failed to update

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.set_polling_interval(3000)
      {:ok, %Setting{}}
  """
  def set_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms >= 1000 do
    Logger.info("SQS Polling Manager: Setting polling interval to #{interval_ms}ms")
    Emails.set_sqs_polling_interval(interval_ms)
  end

  def set_polling_interval(interval_ms) do
    {:error, "Invalid interval: #{interval_ms}. Must be >= 1000ms"}
  end

  @doc """
  Triggers an immediate polling job.

  This creates a new job that will execute as soon as possible,
  regardless of the normal polling schedule.

  The job carries `args: %{"forced" => true}`, which
  `SQSPollingJob.perform/1` honours by bypassing the
  `sqs_polling_enabled` toggle for that single cycle (it still respects
  the system switch, the SES-events switch, and the sender-aware gate).
  Without it a manual poll while the toggle is off would insert a job
  that runs, sees polling disabled, and silently does nothing. The
  distinct args also keep this insert in its own uniqueness namespace,
  so it never moves or cancels the regular chain's next scheduled tick
  — see `insert_forced_poll_job/0`.

  ## Returns

  - `{:ok, job}` - Successfully created immediate job
  - `{:error, reason}` - Failed to create job

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()
      {:ok, %Oban.Job{}}
  """
  def poll_now do
    Logger.info("SQS Polling Manager: Triggering immediate poll")

    unless polling_enabled?() do
      Logger.warning("SQS Polling Manager: Polling is disabled, but executing manual poll")
    end

    case insert_forced_poll_job() do
      {:ok, job} ->
        Logger.info("SQS Polling Manager: Immediate poll job created", %{job_id: job.id})
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("SQS Polling Manager: Failed to create immediate poll job", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Returns the current status of SQS polling.

  ## Returns

  A map with:
  - `enabled` - Whether polling is enabled
  - `interval_ms` - Current polling interval
  - `pending_jobs` - Number of scheduled jobs
  - `last_run` - Timestamp of last completed job (if any)
  - `queue_url` - Configured SQS queue URL

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.status()
      %{
        enabled: true,
        interval_ms: 5000,
        pending_jobs: 1,
        last_run: ~U[2025-09-20 15:30:45Z],
        queue_url: "https://sqs.eu-north-1.amazonaws.com/..."
      }
  """
  def status do
    config = Emails.get_sqs_config()

    pending_jobs = count_pending_jobs()
    last_completed = get_last_completed_job()

    %{
      enabled: config.polling_enabled,
      interval_ms: config.polling_interval_ms,
      pending_jobs: pending_jobs,
      last_run: last_completed && last_completed.completed_at,
      queue_url: config.queue_url,
      aws_region: config.aws_region,
      max_messages_per_poll: config.max_messages_per_poll,
      system_enabled: Emails.enabled?(),
      ses_events_enabled: Emails.ses_events_enabled?()
    }
  end

  ## --- Private Functions ---

  # Insert an immediately-available polling job to start the chain on
  # enable_polling/0. (poll_now/0 uses insert_forced_poll_job/0 below —
  # deliberately a separate insert, see there.)
  #
  # A per-call unique:/replace: override, NOT the job's own worker-level
  # default (which only covers :scheduled — see SQSPollingJob's moduledoc).
  # This one also covers :available, so a double-click or an enable while a
  # next-tick is already queued collapses into ONE row instead of two: on a
  # conflict, `replace:` moves the EXISTING job's scheduled_at to right now
  # (whichever state it's in — :scheduled or already :available) rather than
  # leaving a stray future job alongside a fresh immediate one. `:executing`
  # is deliberately excluded here too, same self-conflict reason as the
  # worker-level default; a job already executing when this fires just gets
  # a genuinely new, separate immediate job queued right behind it, which is
  # the correct "poll now" behavior, not a bug.
  #
  # `schedule_in: 0` is explicit and load-bearing, not decorative: Oban's
  # `replace:` only copies a field that's actually present in the NEW
  # insert's changeset changes (`Job.put_scheduling/2`), and a bare
  # `new(%{})` with no schedule option leaves `:scheduled_at` untouched —
  # `replace: [scheduled: [:scheduled_at]]` would then have nothing to
  # copy onto a conflicting future job, silently failing to move it up.
  # (A job with `scheduled_at` == now lands in Oban's `:scheduled` state,
  # not `:available` — see `Job.normalize_state/1` — but its
  # `scheduled_at` has already "elapsed", so Oban's staging sweep
  # (~1s cadence) picks it up next tick regardless; functionally
  # immediate for this use case.)
  defp insert_poll_job do
    %{}
    |> SQSPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  # `args: %{"forced" => true}` differs from the regular chain's `%{}` in two
  # load-bearing ways (mirrors BrevoPollingManager.insert_forced_poll_job/0):
  #
  #   1. `SQSPollingJob.perform/1` treats it as "run this cycle even though
  #      the sqs_polling_enabled toggle is off". Reusing insert_poll_job/0
  #      here made poll_now/0 a silent no-op whenever polling was disabled —
  #      the one case an operator is most likely to click it — even though
  #      poll_now/0 logs "Polling is disabled, but executing manual poll".
  #   2. Oban's unique check matches on args by default, so this can only
  #      ever conflict with ANOTHER forced job, never the regular chain.
  #      Repeated poll_now/0 calls collapse into one (moved to run now via
  #      replace:) without touching the regular chain's own next scheduled
  #      tick — which sharing insert_poll_job/0 did, resetting the cadence
  #      on every manual poll.
  #
  # `schedule_in: 0` — same reason as insert_poll_job/0 above.
  defp insert_forced_poll_job do
    %{"forced" => true}
    |> SQSPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  # Check if polling is currently enabled
  defp polling_enabled? do
    Emails.sqs_polling_enabled?()
  end

  # Count pending/scheduled SQS polling jobs
  defp count_pending_jobs do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = SQSPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end

  # Get the last completed job
  defp get_last_completed_job do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = SQSPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state == "completed",
      order_by: [desc: j.completed_at],
      limit: 1
    )
    |> repo.one()
  rescue
    _ -> nil
  end
end
