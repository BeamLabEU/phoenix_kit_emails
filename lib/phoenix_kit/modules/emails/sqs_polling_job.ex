defmodule PhoenixKit.Modules.Emails.SQSPollingJob do
  @moduledoc """
  Oban worker for polling AWS SQS queue for email events.

  This is the sole SQS poller: an Oban-based approach that allows dynamic
  enabling/disabling without an application restart (see `SQSPollingManager`).

  ## Architecture

  ```
  AWS SES → SNS Topic → SQS Queue → SQSPollingJob (Oban) → SQSProcessor → Database
  ```

  ## Features

  - **Dynamic Configuration**: Automatically responds to settings changes without restart
  - **Oban Integration**: Uses Oban's job system for reliable background processing
  - **Self-Scheduling**: Each job schedules the next polling cycle
  - **Batch Processing**: Process up to 10 messages at a time
  - **Error Handling**: Retry logic with Dead Letter Queue
  - **Settings-Based Control**: Polling can be enabled/disabled via Settings

  ## Configuration

  All settings are retrieved from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable polling (checked before each cycle)
  - `sqs_polling_interval_ms` - interval between polling cycles
  - `sqs_max_messages_per_poll` - maximum messages per batch
  - `sqs_visibility_timeout` - time for message processing
  - `aws_sqs_queue_url` - SQS queue URL
  - `aws_region` - AWS region

  ## Usage

      # Enable polling (starts first job)
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

      # Disable polling (stops scheduling new jobs)
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()

      # Trigger immediate polling
      PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()

      # Check status
      PhoenixKit.Modules.Emails.SQSPollingManager.status()

  ## Oban Queue Configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        repo: YourApp.Repo,
        queues: [
          sqs_polling: 1  # Only one concurrent polling job
        ]

  ## Implementation Notes

  - Uses Oban's own `unique:` (not a manual delete-then-insert) to keep
    exactly one future job queued — see the `unique:` option below for
    the full reasoning; it's the subtle part of this module.
  - Schedules next job only if polling is enabled
  - Uses `SQSProcessor` for event processing

  ## Why `unique: [period: :infinity, states: [:scheduled]]`, not more

  This looks under-specified at first glance — Oban's own unique-states
  groups (`:incomplete`, or the full default) include `:executing`,
  `:available`, `:retryable` too. Each of those is excluded here for a
  concrete reason, not an oversight:

  - **`:executing` must never be in this worker-level list.** The chain
    works by a currently-`:executing` job inserting its own successor
    from inside `perform/1`. Oban marks a job `:executing` in the DB
    *before* calling `perform/1`, and its unique-conflict check has no
    self-exclusion — an insert of the same worker/args while `:executing`
    is in `states` finds that job's *own* row as the "existing" match and
    no-ops against it instead of creating a new `:scheduled` row. The
    chain would silently stop advancing every single cycle, not just on
    a crash. (A job orphaned in `:executing` by a hard kill would make
    this permanent, on top of merely stalling per-cycle.)
  - **A wider list (e.g. adding `:available`) fails the build.** Oban's
    `use Oban.Worker, unique: [...]` option is checked at compile time
    (`Oban.Worker.__after_compile__/2` → `Job.warn_unique/1`): any
    `:states` list other than the exact literal `[:scheduled]` that
    doesn't cover every "incomplete" state (`:scheduled`, `:available`,
    `:executing`, `:retryable`, `:suspended`) emits a compiler warning
    ("may break uniqueness"), which `--warnings-as-errors` turns into a
    build failure. `[:scheduled]` alone is Oban's own special-cased
    exception to that check (see `Job.warn_unique/1`) — it is the *only*
    partial list that both compiles clean and excludes `:executing`.
  - `[:scheduled]` is exactly enough for THIS insert: self-scheduled jobs
    always land in `:scheduled` (interval >= 1000ms ⇒ schedule_in >= 1s,
    never `:available`), so it dedups the self-reschedule chain against
    itself with no manual delete step. `period: :infinity` (not a short
    window) makes that hold regardless of how long the configured
    interval is — a short window only caught *near-simultaneous* double
    inserts; the old delete-then-insert dance existed specifically to
    catch the case a short window couldn't (two chains a full interval
    apart). An unconditional `:infinity` unique check removes the need
    for that dance entirely.
  - The immediate job from `SQSPollingManager.enable_polling/0` /
    `poll_now/0` is a **different** insert with its own **per-call**
    `unique:`/`replace:` override (`states: [:available, :scheduled]`) —
    see `SQSPollingManager`'s `insert_poll_job/0` and
    `insert_forced_poll_job/0`. A per-call override on `new/2` does NOT
    go through the compile-time check above (only the worker-level `use`
    default does), so it's free to cover `:available` too. It still
    excludes `:executing` for the same self-conflict reason. `poll_now/0`
    additionally carries `args: %{"forced" => true}`, which puts it in a
    separate uniqueness namespace (Oban matches on args) so a manual poll
    never moves the regular chain's next tick.
  - Concurrency is capped at 1 by the queue, so parallel *execution* is
    already impossible; `unique:` is what prevents parallel *chains*.
  """

  use Oban.Worker,
    queue: :sqs_polling,
    max_attempts: 3,
    unique: [period: :infinity, states: [:scheduled]]

  require Logger

  import Ecto.Query

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSProcessor

  @default_long_poll_timeout 20

  # Back-off interval used when the config is (recoverably) invalid, so a
  # misconfigured system is not polled at the full rate while it keeps failing.
  @misconfig_backoff_ms 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # `forced: true` (SQSPollingManager.poll_now/0) bypasses the
    # sqs_polling_enabled toggle specifically — an operator asking for
    # events right now shouldn't be silently ignored just because the
    # background chain is off — but never bypasses Emails.enabled?/0, the
    # SES-events switch, or the sender-aware gate (see
    # pollable_ignoring_toggle?/0). schedule_next_poll/1 re-checks
    # should_poll?/0 on its own, so a forced run while the toggle is off
    # still runs once without resurrecting the self-scheduling chain.
    # Mirrors BrevoPollingJob.perform/1.
    forced? = Map.get(args || %{}, "forced", false)

    # Check if polling is enabled before processing
    if should_poll?() or (forced? and pollable_ignoring_toggle?()) do
      Logger.debug("SQS Polling Job: Starting polling cycle")

      config = Emails.get_sqs_config()

      # The self-scheduling chain owns continuation; the poll interval IS the
      # retry cadence. We ALWAYS schedule the next cycle while polling is enabled
      # and return :ok — never {:error}. Returning {:error} would either spawn a
      # duplicate chain (Oban retry + self-schedule both firing) or, once the 3
      # Oban attempts are exhausted on a sustained outage, let the chain die
      # permanently until an app restart. A transient receive error simply
      # retries on the next scheduled poll; a recoverable misconfiguration backs
      # off but keeps the chain alive so it resumes once fixed.
      # unique: [period: :infinity, states: [:scheduled]] on the worker (see
      # moduledoc) keeps this to exactly one chain — no manual cleanup needed.
      next_interval =
        case validate_configuration(config) do
          :ok ->
            log_cycle_result(perform_polling_cycle(config))
            config.polling_interval_ms

          {:error, reason} ->
            Logger.error("SQS Polling Job: Invalid configuration - #{reason}")
            @misconfig_backoff_ms
        end

      schedule_next_poll(next_interval)
      :ok
    else
      Logger.debug("SQS Polling Job: Polling disabled, skipping cycle")
      :ok
    end
  end

  # A failed polling cycle does not fail the Oban job (the chain self-continues);
  # we log it loudly so a sustained outage stays observable.
  defp log_cycle_result({:ok, _}), do: :ok

  defp log_cycle_result({:error, reason}) do
    Logger.error("SQS Polling Job: Polling cycle failed", %{reason: inspect(reason)})
    :ok
  end

  @doc """
  Returns the Oban `worker` column value for this job.

  Single source of truth for callers that query `Oban.Job` by worker name
  (e.g. `SQSPollingManager`), so they never drift from `inspect(__MODULE__)`.
  """
  @spec worker_name() :: String.t()
  def worker_name, do: inspect(__MODULE__)

  defp get_repo do
    PhoenixKit.RepoHelper.repo()
  end

  ## --- Private Functions ---

  @doc false
  # Check if polling should be performed. Not `defp` so the sender-aware
  # gate can be unit-tested directly without a real SQS/network round trip.
  def should_poll? do
    Emails.sqs_polling_enabled?() and pollable_ignoring_toggle?()
  end

  @doc false
  # Everything the poller needs EXCEPT the sqs_polling_enabled toggle: the
  # system switch, the SES-events switch, a queue to poll, and the
  # sender-aware gate below. A forced (poll_now/0) cycle bypasses the
  # toggle but never these — mirroring BrevoPollingJob, whose `forced?`
  # bypasses brevo_events_enabled but never Emails.enabled?/0 or its
  # profile gate. This is exactly `EventTracker.eligible?/0`'s SES
  # definition (SQSPollingManager.eligible?/0 delegates here) — not `defp`
  # for that reuse, same testability rationale as `should_poll?/0` above.
  def pollable_ignoring_toggle? do
    Emails.enabled?() and
      Emails.ses_events_enabled?() and
      queue_url_configured?() and
      ses_actively_configured?()
  end

  # Carries the precondition that used to live in the supervisor's own
  # `has_sqs_configuration?/0` boot gate. Once boot started going through
  # `EventTrackerReconciler.reconcile/0`, eligible?/0 became the only gate
  # left, and without this a deployment with SES credentials and the toggle
  # on but no queue URL would start a chain at boot, have the reconcile Cron
  # resurrect it every couple of minutes, and log `validate_configuration/1`'s
  # "SQS queue URL not configured" on the @misconfig_backoff_ms cadence
  # forever — while the admin panel, seeing live jobs, called it :active /
  # "Running normally". Folded into eligible?/0 the same state reads
  # :idle_no_integration, which is what it is. Checked before the
  # sender-aware gate: a Settings read, no DB round trip.
  defp queue_url_configured? do
    url = Emails.get_sqs_config().queue_url

    is_binary(url) and url != ""
  end

  # Sender-aware gate, mirroring the (parallel) Brevo poller design — see
  # PR #18 (BrevoPollingJob isn't on main yet, so there's nothing to
  # literally reference here). SQS credentials being *reachable* isn't
  # the same as SES actually being the thing sending mail right now. Two
  # ways to count as "actively configured":
  #
  #   - `Emails.aws_configured?/0` — the explicit override: SQS polling
  #     predates the SendProfile system, and plenty of deployments still
  #     configure SES directly (legacy `aws_access_key_id`/
  #     `aws_secret_access_key` Settings, env vars, or a bare `aws_ses`
  #     Integrations connection with no SendProfile pointed at it at
  #     all). Requiring a SendProfile unconditionally would silently stop
  #     polling for every one of those pre-existing setups. Checked
  #     first — it's the cached lookup (`PhoenixKit.Cache`-backed, see
  #     `Emails.aws_ses_credentials/0`), cheaper than the DB round trip
  #     below.
  #   - an enabled SendProfile pointed at an `"aws_ses"` integration (the
  #     current, profile-based way to wire up a sender).
  defp ses_actively_configured? do
    Emails.aws_configured?() or has_enabled_ses_send_profile?()
  end

  defp has_enabled_ses_send_profile? do
    SendProfile
    |> where([sp], sp.enabled == true and sp.provider_kind == "aws_ses")
    |> limit(1)
    |> get_repo().exists?()
  end

  # Validate SQS configuration
  defp validate_configuration(config) do
    cond do
      is_nil(config.queue_url) or config.queue_url == "" ->
        {:error, "SQS queue URL not configured"}

      not is_integer(config.polling_interval_ms) or config.polling_interval_ms < 1000 ->
        # Sub-second intervals round down to schedule_in: 0 (Oban schedules in
        # whole seconds), causing a back-to-back poll loop. Mirror
        # SQSPollingManager.set_polling_interval/1's >= 1000 guard.
        {:error, "Invalid polling interval (must be >= 1000ms)"}

      not is_integer(config.max_messages_per_poll) or
        config.max_messages_per_poll <= 0 or
          config.max_messages_per_poll > 10 ->
        {:error, "Invalid max messages per poll (must be 1-10)"}

      not is_integer(config.visibility_timeout) or config.visibility_timeout <= 0 ->
        {:error, "Invalid visibility timeout"}

      true ->
        :ok
    end
  end

  # Perform one polling cycle
  defp perform_polling_cycle(config) do
    _start_time = System.monotonic_time(:millisecond)

    case receive_messages(config) do
      {:ok, [_ | _] = messages} ->
        Logger.info("SQS Polling Job: Received #{length(messages)} messages")

        processing_start = System.monotonic_time(:millisecond)
        processed_count = process_messages(messages, config)
        processing_time = System.monotonic_time(:millisecond) - processing_start

        Logger.info(
          "SQS Polling Job: Processed #{processed_count}/#{length(messages)} messages in #{processing_time}ms"
        )

        {:ok,
         %{processed: processed_count, total: length(messages), duration_ms: processing_time}}

      {:ok, []} ->
        Logger.debug("SQS Polling Job: No messages in queue")
        {:ok, %{processed: 0, total: 0}}

      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to receive messages", %{
          reason: inspect(reason),
          queue_url: config.queue_url
        })

        {:error, reason}
    end
  end

  # Receive messages from SQS queue
  defp receive_messages(config) do
    aws_config = build_aws_config(config)

    request =
      ExAws.SQS.receive_message(
        config.queue_url,
        max_number_of_messages: config.max_messages_per_poll,
        wait_time_seconds: @default_long_poll_timeout,
        visibility_timeout: config.visibility_timeout,
        message_attribute_names: [:all],
        attribute_names: [:all]
      )

    case ExAws.request(request, aws_config) do
      {:ok, %{"Messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{"messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, _response} ->
        {:ok, []}

      {:error, error} ->
        Logger.error("SQS Polling Job: ExAws request failed", %{
          error: inspect(error),
          queue_url: config.queue_url
        })

        {:error, error}
    end
  end

  # Process message list in parallel
  defp process_messages(messages, config) do
    aws_config = build_aws_config(config)

    tasks =
      Enum.map(messages, fn message ->
        Task.async(fn ->
          process_single_message(message, config.queue_url, aws_config)
        end)
      end)

    # yield_many (not await_many) so a slow task can't RAISE and abort the whole
    # perform/1: a raised timeout would trigger an Oban retry and tear down the
    # in-flight delete_message calls, re-cycling messages. Tasks that yield
    # {:ok, true} count as processed; un-yielded/timed-out ones are shut down and
    # treated as not-processed, so their messages simply re-receive normally
    # after the SQS visibility timeout.
    tasks
    |> Task.yield_many(30_000)
    |> Enum.count(fn {task, result} ->
      case result || Task.shutdown(task, :brutal_kill) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  # Process a single message.
  #
  # ExAws.SQS may return messages with either string keys ("ReceiptHandle") or
  # atom keys (:receipt_handle, from the `%{body: %{messages: [...]}}` parsed
  # shape that receive_messages/1 also accepts). Read both, otherwise the
  # receipt handle comes back nil and delete_message/3 silently fails, leaving
  # the message to be re-received forever.
  defp process_single_message(message, queue_url, aws_config) do
    message_id = message["MessageId"] || message[:message_id]
    receipt_handle = message["ReceiptHandle"] || message[:receipt_handle]

    with {:ok, event_data} <- SQSProcessor.parse_sns_message(message),
         {:ok, _result} <- SQSProcessor.process_email_event(event_data),
         :ok <- delete_message(queue_url, receipt_handle, aws_config) do
      true
    else
      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to process message", %{
          message_id: message_id,
          reason: inspect(reason)
        })

        false
    end
  end

  # Delete processed message from queue. Returns the failure (instead of
  # swallowing it as :ok) so a message that wasn't actually deleted is not
  # counted as processed — the silent :ok previously hid a nil-receipt-handle
  # bug that made messages re-cycle forever.
  defp delete_message(_queue_url, nil, _aws_config) do
    Logger.error("SQS Polling Job: Missing receipt handle, cannot delete message")
    {:error, :missing_receipt_handle}
  end

  defp delete_message(queue_url, receipt_handle, aws_config) do
    ExAws.SQS.delete_message(queue_url, receipt_handle)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("SQS Polling Job: Failed to delete message", %{
          error: inspect(error),
          queue_url: queue_url
        })

        {:error, error}
    end
  end

  @doc false
  # Schedule next polling job. Relies entirely on the worker's own
  # `unique: [period: :infinity, states: [:scheduled]]` (see moduledoc) to
  # guarantee exactly one queued future job — no manual delete-then-insert.
  # A conflict here (job.conflict? == true) means another :scheduled job
  # already exists; that's the expected, harmless steady state (e.g. this
  # cycle racing an enable_polling/poll_now insert), not an error. Not
  # `defp` so the dedup behavior is unit-testable directly — same
  # rationale as `should_poll?/0` above.
  def schedule_next_poll(interval_ms) do
    if should_poll?() do
      # Oban schedule_in is in whole SECONDS — div(interval_ms, 1000) is 0 for
      # any 1..999ms interval, which would queue the next poll immediately and
      # spin a back-to-back loop. Floor at 1s. (validate_configuration/1 already
      # rejects sub-second intervals; this is a defensive backstop.)
      %{}
      |> __MODULE__.new(schedule_in: max(div(interval_ms, 1000), 1))
      |> Oban.insert()
      |> case do
        {:ok, %Oban.Job{conflict?: true}} ->
          Logger.debug("SQS Polling Job: Next poll already scheduled, skipping duplicate insert")

          :ok

        {:ok, _job} ->
          Logger.debug("SQS Polling Job: Next poll scheduled in #{interval_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("SQS Polling Job: Failed to schedule next poll", %{
            reason: inspect(reason)
          })

          :ok
      end
    else
      Logger.debug("SQS Polling Job: Polling disabled, not scheduling next poll")
      :ok
    end
  end

  # Build AWS configuration
  defp build_aws_config(config) do
    if is_binary(config.aws_access_key_id) and config.aws_access_key_id != "" and
         is_binary(config.aws_secret_access_key) and config.aws_secret_access_key != "" and
         is_binary(config.aws_region) and config.aws_region != "" do
      [
        access_key_id: String.trim(config.aws_access_key_id),
        secret_access_key: String.trim(config.aws_secret_access_key),
        region: String.trim(config.aws_region)
      ]
    else
      []
    end
  end
end
