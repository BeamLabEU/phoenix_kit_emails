defmodule PhoenixKit.Modules.Emails.BrevoPollingJobSchedulingTest do
  @moduledoc """
  `schedule_next_poll/1`'s dedup, now backed by Oban's own
  `unique: [period: :infinity, states: [:scheduled]]` instead of a manual
  delete-then-insert — mirrors `SQSPollingJobSchedulingTest`; see
  `SQSPollingJob`'s moduledoc "Why unique: ..., not more" for the full
  reasoning (`BrevoPollingJob`'s `use Oban.Worker` block points there
  rather than duplicating it).
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_brevo_events_enabled(true)
    :ok
  end

  defp worker_jobs(states) do
    worker = BrevoPollingJob.worker_name()
    Repo.all(from(j in Oban.Job, where: j.worker == ^worker and j.state in ^states))
  end

  test "calling schedule_next_poll/1 twice inserts exactly one :scheduled job" do
    assert :ok = BrevoPollingJob.schedule_next_poll(120_000)
    assert :ok = BrevoPollingJob.schedule_next_poll(120_000)

    assert [%Oban.Job{state: "scheduled"}] = worker_jobs(["scheduled"])
  end

  test "a job in :executing state does not block scheduling the next one — both coexist" do
    {:ok, executing_job} = %{} |> BrevoPollingJob.new(schedule_in: 60) |> Oban.insert()

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^executing_job.id),
      set: [state: "executing"]
    )

    assert :ok = BrevoPollingJob.schedule_next_poll(120_000)

    jobs = worker_jobs(["executing", "scheduled"])
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.state == "executing" and &1.id == executing_job.id))
    assert Enum.any?(jobs, &(&1.state == "scheduled"))
  end
end
