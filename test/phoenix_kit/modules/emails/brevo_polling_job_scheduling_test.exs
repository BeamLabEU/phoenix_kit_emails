defmodule PhoenixKit.Modules.Emails.BrevoPollingJobSchedulingTest do
  @moduledoc """
  `schedule_next_poll/1`'s dedup, now backed by Oban's own
  `unique: [period: :infinity, states: [:scheduled]]` instead of a manual
  delete-then-insert — mirrors `SQSPollingJobSchedulingTest`; see
  `SQSPollingJob`'s moduledoc "Why unique: ..., not more" for the full
  reasoning (`BrevoPollingJob`'s `use Oban.Worker` block points there
  rather than duplicating it).

  Every test needs an active `brevo_api` profile: `should_poll?/0` (what
  `schedule_next_poll/1` gates on) now requires one — see task #56's
  fix-batch item 2, matching `EventTracker.should_run?/1`'s definition
  for this tracker exactly.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_brevo_events_enabled(true)
    create_brevo_profile()
    :ok
  end

  defp create_brevo_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: true
      })

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

  test "with zero active brevo_api profiles, schedule_next_poll/1 does not resurrect the chain" do
    # Regression for task #56 fix-batch item 2: should_poll?/0 used to
    # ignore profile presence entirely ("keep spinning so a future
    # profile is picked up without a manual re-trigger") — now it's
    # exactly EventTracker.should_run?/1 for this tracker, so a chain
    # with no active profile lets itself die (the reconcile Cron
    # resurrects it once a profile exists again, not this).
    {:ok, _} = SendProfiles.list_send_profiles() |> hd() |> SendProfiles.delete_send_profile()

    assert :ok = BrevoPollingJob.schedule_next_poll(120_000)
    assert worker_jobs(["available", "scheduled"]) == []
  end
end
