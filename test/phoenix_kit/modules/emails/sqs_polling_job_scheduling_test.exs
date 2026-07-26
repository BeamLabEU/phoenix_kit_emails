defmodule PhoenixKit.Modules.Emails.SQSPollingJobSchedulingTest do
  @moduledoc """
  `schedule_next_poll/1`'s dedup, now backed by Oban's own
  `unique: [period: :infinity, states: [:scheduled]]` instead of a manual
  delete-then-insert (see `SQSPollingJob`'s moduledoc "Why unique: ...,
  not more"). Exercises `schedule_next_poll/1` directly (public, `@doc
  false`) rather than through `perform/1`, so these tests aren't coupled
  to the AWS/SES receive cycle.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_ses_events(true)
    {:ok, _} = Emails.set_sqs_polling(true)
    create_ses_profile()
    :ok
  end

  defp create_ses_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "secret"
      })

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  defp worker_jobs(states) do
    worker = SQSPollingJob.worker_name()
    Repo.all(from(j in Oban.Job, where: j.worker == ^worker and j.state in ^states))
  end

  test "calling schedule_next_poll/1 twice inserts exactly one :scheduled job" do
    assert :ok = SQSPollingJob.schedule_next_poll(5_000)
    assert :ok = SQSPollingJob.schedule_next_poll(5_000)

    assert [%Oban.Job{state: "scheduled"}] = worker_jobs(["scheduled"])
  end

  test "a job in :executing state does not block scheduling the next one — both coexist" do
    {:ok, executing_job} = %{} |> SQSPollingJob.new(schedule_in: 60) |> Oban.insert()

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^executing_job.id),
      set: [state: "executing"]
    )

    assert :ok = SQSPollingJob.schedule_next_poll(5_000)

    jobs = worker_jobs(["executing", "scheduled"])
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.state == "executing" and &1.id == executing_job.id))
    assert Enum.any?(jobs, &(&1.state == "scheduled"))
  end
end
