defmodule PhoenixKit.Modules.Emails.ArchiveWorker do
  @moduledoc """
  The scheduled half of S3 archival.

  `Archiver.archive_to_s3/2` has always been callable by hand; nothing ever
  called it. A feature whose only trigger is an operator remembering to open a
  console is not a retention policy, so this worker is what makes "archive to
  S3" mean something on its own.

  ## What a tick does

  Nothing at all unless the emails system is enabled AND `email_archive_to_s3`
  is on AND a bucket is set. Each of those is a deliberate no-op rather than an
  error: a disabled feature firing errors every cron tick trains operators to
  ignore the log.

  When it does run, it archives everything older than `email_retention_days`
  that has not already been shipped, keeping the rows in place. Deletion is
  left to the retention cleanup, which — while archival is on — refuses to
  delete a row this job has not stamped yet (see
  `PhoenixKit.Modules.Emails.Log.cleanup_old_logs/2`). The two jobs therefore
  hand work to each other in one direction only: archive, then delete. There is
  no ordering requirement between them and no window in which an unarchived row
  can be dropped.

  ## Frequency

  Hourly is the intended cadence. The work is proportional to what has aged
  past the cutoff since the last tick, which on a steady stream is a small
  batch, and the `unique` below means a slow run is never overlapped by the
  next tick rather than being run twice against the same rows.

  ## Oban queue + cron configuration

      config :your_app, Oban,
        queues: [
          email_archival: 1,
          # ... your other queues
        ],
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"0 * * * *", PhoenixKit.Modules.Emails.ArchiveWorker}
           ]}
        ]

  Without that entry the feature is exactly as inert as it was before this
  worker existed — the settings page says so rather than implying a schedule
  that does not exist.
  """

  use Oban.Worker,
    queue: :email_archival,
    max_attempts: 3,
    # A run that outlives its interval must not be joined by the next tick:
    # both would select the same not-yet-stamped rows and upload them twice.
    # `:incomplete` rather than a hand-listed set — it also covers `:retryable`
    # and `:suspended`, which a hand-written list silently omits (Oban warns
    # about exactly this).
    unique: [period: 3600, states: :incomplete]

  require Logger

  alias PhoenixKit.Modules.Emails

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Emails.archive_to_s3() do
      {:ok, :skipped} ->
        :ok

      {:ok, 0} ->
        :ok

      {:ok, count} when is_integer(count) ->
        Logger.info("Email archival: shipped #{count} logs to S3")
        :ok

      # `:no_bucket_configured` is a configuration gap, not a failure to retry:
      # the next tick will hit it again, and retrying inside this one only
      # burns attempts. Logged once per tick, at a level an operator can filter.
      {:error, reason} when reason in [:s3_not_configured, :no_bucket_configured] ->
        Logger.warning("Email archival: enabled but not configured (#{inspect(reason)})")
        :ok

      {:error, reason} ->
        Logger.error("Email archival failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
