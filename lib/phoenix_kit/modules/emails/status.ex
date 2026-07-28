defmodule PhoenixKit.Modules.Emails.Status do
  @moduledoc """
  One snapshot of what the email system is actually doing right now.

  Exists because every failure mode in this package is silent by design: the
  interceptor swallows its own errors so a logging problem can never break a
  send. That is the right trade — but it means an operator looking at "Email
  system: enabled" has no way to tell it apart from "enabled and recording
  nothing". `summary/0` answers the questions the settings page should not have
  to guess at:

    * is the system on;
    * *is anything being logged*, and if not, why;
    * which mailer the messages actually leave through;
    * is the queue on, and can it even run (the `:emails` Oban queue lives in
      the host application's config — a package cannot add it);
    * what has happened today.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Queue
  alias PhoenixKit.RepoHelper

  # Mirrors the Log changeset's own rule. A sender that fails it makes every
  # insert fail, which the interceptor logs and swallows — the "enabled but
  # recording nothing" trap this module exists to expose.
  @sender_regex ~r/^[^\s]+@[^\s]+\.[^\s]+$/

  @type t :: %{
          system_enabled: boolean(),
          logging: :active | :system_disabled | :sender_invalid,
          sender: %{email: String.t(), loggable?: boolean()},
          transport: %{kind: :integration | :static, name: String.t() | nil, adapter: String.t()},
          queue: map(),
          save_body: boolean(),
          sampling_rate: integer(),
          today: %{logged: integer(), sent: integer(), failed: integer(), queued: integer()}
        }

  @doc "Everything the settings page needs, in one read."
  @spec summary() :: t()
  def summary do
    sender = sender_info()
    system_enabled = Emails.enabled?()

    %{
      system_enabled: system_enabled,
      logging: logging_state(system_enabled, sender),
      sender: sender,
      transport: transport_info(),
      queue: queue_info(),
      save_body: Emails.save_body_enabled?(),
      sampling_rate: Emails.get_sampling_rate(),
      today: today_counts()
    }
  end

  defp logging_state(false, _sender), do: :system_disabled
  defp logging_state(true, %{loggable?: false}), do: :sender_invalid
  defp logging_state(true, _sender), do: :active

  defp sender_info do
    email = PhoenixKit.Mailer.get_from_email()
    %{email: email, loggable?: is_binary(email) and Regex.match?(@sender_regex, email)}
  end

  defp transport_info do
    case default_integration() do
      {:ok, uuid, name} ->
        %{kind: :integration, name: name, adapter: uuid}

      :none ->
        mailer = PhoenixKit.Mailer.get_mailer()
        %{kind: :static, name: nil, adapter: adapter_name(mailer)}
    end
  end

  # Mirrors PhoenixKit.Mailer.default_send_integration_uuid/0 — including the
  # `connected?/1` gate. Without it a configured-but-disconnected integration
  # would be named here as the transport while the mailer quietly falls back to
  # the static one: a status card that reports the wrong sender is worse than no
  # card.
  defp default_integration do
    with uuid when is_binary(uuid) and uuid != "" <-
           PhoenixKit.Settings.get_setting("default_email_integration_uuid"),
         true <- PhoenixKit.Integrations.connected?(uuid),
         {:ok, integration} <- PhoenixKit.Integrations.get_integration_by_uuid(uuid) do
      {:ok, uuid, integration[:name] || integration["name"]}
    else
      _ -> :none
    end
  end

  defp adapter_name(mailer) do
    app = PhoenixKit.Config.get_parent_app()

    config =
      if mailer == PhoenixKit.Mailer,
        do: Application.get_env(:phoenix_kit, mailer, []),
        else: Application.get_env(app, mailer, [])

    case config[:adapter] do
      nil -> "—"
      adapter -> adapter |> to_string() |> String.replace_prefix("Elixir.", "")
    end
  end

  defp queue_info do
    base = %{
      enabled?: Queue.enabled?(),
      auth_mail?: Queue.auth_mail_enabled?(),
      status: Queue.status(),
      oban_queue_configured?: oban_queue_configured?()
    }

    Map.merge(base, job_counts())
  end

  # The queue name lives in the HOST's Oban config; without it jobs would be
  # inserted and never picked up, so Queue refuses to enqueue and sends inline.
  # Surfaced here so the operator learns it from the page rather than from mail
  # that goes out without ever appearing in the queue.
  defp oban_queue_configured?, do: Queue.runnable?()

  defp job_counts do
    counts =
      Oban.Job
      |> where([j], j.queue == "emails")
      |> where([j], j.state in ["available", "scheduled", "executing", "retryable"])
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> RepoHelper.repo().all()
      |> Map.new()

    %{
      pending: Map.get(counts, "available", 0) + Map.get(counts, "scheduled", 0),
      executing: Map.get(counts, "executing", 0),
      retryable: Map.get(counts, "retryable", 0)
    }
  rescue
    # Oban's table may live in another prefix, or Oban may not be running at
    # all in a host that only uses the logging half of this package.
    _ -> %{pending: 0, executing: 0, retryable: 0}
  end

  defp today_counts do
    start_of_day =
      DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    rows =
      Log
      |> where([l], l.inserted_at >= ^start_of_day)
      |> group_by([l], l.status)
      |> select([l], {l.status, count(l.uuid)})
      |> RepoHelper.repo().all()
      |> Map.new()

    %{
      logged: rows |> Map.values() |> Enum.sum(),
      sent: Map.get(rows, "sent", 0) + Map.get(rows, "delivered", 0),
      failed: Map.get(rows, "failed", 0) + Map.get(rows, "bounced", 0),
      queued: Map.get(rows, "queued", 0)
    }
  rescue
    _ -> %{logged: 0, sent: 0, failed: 0, queued: 0}
  end
end
