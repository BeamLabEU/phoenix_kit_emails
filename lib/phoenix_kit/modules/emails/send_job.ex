defmodule PhoenixKit.Modules.Emails.SendJob do
  @moduledoc """
  Delivers one queued message.

  `PhoenixKit.Modules.Emails.Queue` enqueues the serialized `Swoosh.Email`; this
  worker rebuilds it and hands it back to `PhoenixKit.Mailer.deliver_email/2`
  with `skip_queue: true`, so the real send takes the ordinary path — recipient
  blocklist, integration-or-static-mailer choice, post-send tracking — without
  being offered back to the queue it just came from.

  The message carries its `X-PhoenixKit-Log-Id` header across the hop, so the
  interceptor recognises the already-logged message and updates that row instead
  of writing a second one.

  ## Delivery is at-least-once

  If the relay accepts the message but the connection drops before its reply,
  the send looks like a failure, Oban retries, and the recipient gets the mail
  twice (up to `max_attempts`). That is inherent to handing delivery to a queue
  — it is why authentication mail is excluded by default, and why a caller that
  cannot tolerate a duplicate should pass `queue: false`.

  ## Host setup

  The `:emails` queue must exist in the **host application's** Oban config — a
  package cannot add a queue to someone else's supervision tree:

      config :my_app, Oban, queues: [emails: 10, ...]

  Without it the jobs simply sit in `available` forever, which is why
  `Queue.status/0` is surfaced on the settings page.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Queue

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email_args} = args}) do
    email = Queue.deserialize(email_args)
    opts = args |> Map.get("opts", %{}) |> Queue.deserialize_opts()

    case PhoenixKit.Mailer.deliver_email(email, Keyword.put(opts, :skip_queue, true)) do
      {:ok, _result} ->
        :ok

      # The recipient was blocklisted (hard bounce, complaint, manual block)
      # between enqueue and dequeue. `deliver_email/2` refuses before it ever
      # reaches the after-send hook, so retrying can only fail the same way five
      # more times — and the log row would sit at "queued" forever. Cancel and
      # close the row out instead.
      {:error, {:blocked, _} = reason} ->
        Logger.info("[Emails.SendJob] recipient blocked, cancelling: #{inspect(reason)}")
        fail_log(email, reason)
        {:cancel, :recipient_blocked}

      {:error, reason} ->
        # Return the error so Oban records it and retries with backoff; the log
        # row is updated by the tracking interceptor's after-send hook, which
        # ran inside deliver_email/2.
        Logger.warning("[Emails.SendJob] delivery failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    # A job without an email is unrecoverable — discard rather than retry five
    # times against the same malformed args.
    Logger.error("[Emails.SendJob] malformed job args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  # The log row was written before the hop and is still "queued"; nothing else
  # will close it out once we cancel the job.
  defp fail_log(email, reason) do
    with log_uuid when is_binary(log_uuid) <- Map.get(email.headers || %{}, "X-PhoenixKit-Log-Id"),
         %Emails.Log{} = log <- Emails.get_log(log_uuid) do
      Interceptor.update_after_failure(log, reason)
    end

    :ok
  rescue
    error ->
      Logger.warning("[Emails.SendJob] could not close the log row: #{Exception.message(error)}")
      :ok
  end
end
