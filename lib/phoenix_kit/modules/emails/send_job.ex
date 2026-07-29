defmodule PhoenixKit.Modules.Emails.SendJob do
  @moduledoc """
  Delivers one queued message.

  `PhoenixKit.Modules.Emails.Queue` enqueues the serialized `Swoosh.Email`; this
  worker rebuilds it and hands it back to `PhoenixKit.Mailer.deliver_email/2`
  with `skip_queue: true` and `already_intercepted: true`, so the real send takes
  the ordinary path — recipient blocklist, integration-or-static-mailer choice,
  post-send tracking — without being offered back to the queue it just came from
  and without being run through interception a second time.

  The message also carries its `X-PhoenixKit-Log-Id` header across the hop, so
  `handle_after_send/2` updates the row this message already has. The
  interceptor's own idempotency check on that header stays as a second line of
  defence for a core old enough not to know `already_intercepted`.

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

  @log_header "X-PhoenixKit-Log-Id"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email_args} = args} = job) do
    email = Queue.deserialize(email_args)
    opts = args |> Map.get("opts", %{}) |> Queue.deserialize_opts()

    send_opts = opts |> Keyword.put(:skip_queue, true) |> Keyword.put(:already_intercepted, true)

    case PhoenixKit.Mailer.deliver_email(email, send_opts) do
      {:ok, _result} ->
        :ok

      # The recipient was blocklisted (hard bounce, complaint, manual block)
      # between enqueue and dequeue. `deliver_email/2` refuses before it ever
      # reaches the after-send hook, so retrying can only fail the same way five
      # more times — and the log row would sit at "queued" forever. Cancel and
      # close the row out instead.
      {:error, {:blocked, _} = reason} ->
        Logger.info("[Emails.SendJob] recipient blocked, cancelling: #{inspect(reason)}")
        # A readable sentence, not an inspected tuple: this lands in the log
        # row's error_message column, which an operator reads in the UI.
        fail_log(args, "Recipient is on the blocklist")
        {:cancel, :recipient_blocked}

      {:error, reason} ->
        # Return the error so Oban records it and retries with backoff; the log
        # row is updated by the tracking interceptor's after-send hook, which
        # ran inside deliver_email/2.
        Logger.warning("[Emails.SendJob] delivery failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      # A raise (an adapter that throws instead of returning `{:error, _}`, a
      # pool timeout, a malformed body) never reaches core's after-send hook, so
      # unlike the `{:error, _}` branch above nothing has touched the log row —
      # it is still "queued". Oban's own handling still applies (we reraise, so
      # the attempt is recorded and retried), but on the last attempt the job is
      # discarded and nothing else will ever close that row: it would read
      # "queued" forever, the exact silent state this module's status card
      # exists to eliminate.
      if last_attempt?(job), do: fail_log(args, Exception.message(error))

      reraise error, __STACKTRACE__
  end

  def perform(%Oban.Job{args: args}) do
    # A job without an email is unrecoverable — discard rather than retry five
    # times against the same malformed args.
    Logger.error("[Emails.SendJob] malformed job args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  # This job will not run again, and the log row written before the hop is still
  # "queued"; nothing else will close it out.
  #
  # Reads the uuid straight out of the job args rather than off the rebuilt
  # email, so it works from the rescue clause too (where a deserialize that
  # raised leaves no email to read).
  defp fail_log(args, reason) do
    with log_uuid when is_binary(log_uuid) <- args_log_uuid(args),
         %Emails.Log{} = log <- Emails.get_log(log_uuid) do
      Interceptor.update_after_failure(log, reason)
    end

    :ok
  rescue
    error ->
      Logger.warning("[Emails.SendJob] could not close the log row: #{Exception.message(error)}")
      :ok
  end

  defp args_log_uuid(%{"email" => %{"headers" => headers}}) when is_map(headers),
    do: Map.get(headers, @log_header)

  defp args_log_uuid(_args), do: nil

  # `attempt` is 1-based and already incremented for the run in progress, so on
  # the final run it equals `max_attempts` — after this one Oban discards.
  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max})
       when is_integer(attempt) and is_integer(max),
       do: attempt >= max

  defp last_attempt?(_job), do: false
end
