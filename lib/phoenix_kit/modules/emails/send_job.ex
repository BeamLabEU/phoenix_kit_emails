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

  alias PhoenixKit.Modules.Emails.Queue

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email_args} = args}) do
    email = Queue.deserialize(email_args)
    opts = args |> Map.get("opts", %{}) |> Queue.deserialize_opts()

    case PhoenixKit.Mailer.deliver_email(email, Keyword.put(opts, :skip_queue, true)) do
      {:ok, _result} ->
        :ok

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
end
