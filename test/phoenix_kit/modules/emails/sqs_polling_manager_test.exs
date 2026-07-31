defmodule PhoenixKit.Modules.Emails.SQSPollingManagerTest do
  @moduledoc """
  Unit tests for `SQSPollingManager`'s control surface — mirrors
  `BrevoPollingManagerTest`'s contract (enable/disable/poll_now), backed
  by an Oban instance in `testing: :manual` mode so `Oban.insert/1`
  persists a row without actually running the job.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
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

  test "enable_polling/0 persists the setting and inserts the first job" do
    refute Emails.sqs_polling_enabled?()

    assert {:ok, %Oban.Job{}} = SQSPollingManager.enable_polling()
    assert Emails.sqs_polling_enabled?()
  end

  test "disable_polling/0 clears the setting" do
    {:ok, _job} = SQSPollingManager.enable_polling()
    assert :ok = SQSPollingManager.disable_polling()
    refute Emails.sqs_polling_enabled?()
  end

  test "set_polling_interval/1 rejects anything below 1000ms" do
    assert {:error, _} = SQSPollingManager.set_polling_interval(999)
    assert {:ok, _} = SQSPollingManager.set_polling_interval(5_000)
  end

  test "poll_now/0 inserts an immediate forced job even while polling is disabled" do
    refute Emails.sqs_polling_enabled?()
    assert {:ok, %Oban.Job{} = job} = SQSPollingManager.poll_now()

    # The `forced` flag is what makes this actually poll rather than
    # insert a job that no-ops on SQSPollingJob's should_poll?/0 gate.
    assert job.args == %{"forced" => true}
  end

  test "enable_polling/0 while a next tick is already scheduled moves it to run now, not a duplicate" do
    {:ok, existing} = %{} |> SQSPollingJob.new(schedule_in: 3_600) |> Oban.insert()
    assert existing.state == "scheduled"
    far_future = existing.scheduled_at

    assert {:ok, job} = SQSPollingManager.enable_polling()

    # Same row, not a second one — moved up, not appended.
    assert job.id == existing.id
    assert DateTime.compare(job.scheduled_at, far_future) == :lt
    assert DateTime.diff(DateTime.utc_now(), job.scheduled_at, :second) |> abs() < 5

    assert [_single] = worker_jobs(["available", "scheduled"])
  end

  test "poll_now/0 called twice back to back inserts exactly one job" do
    assert {:ok, first} = SQSPollingManager.poll_now()
    assert {:ok, second} = SQSPollingManager.poll_now()

    assert first.id == second.id
    assert [_single] = worker_jobs(["available", "scheduled"])
  end

  test "poll_now/0 does not disturb an already-scheduled regular (non-forced) cycle" do
    {:ok, regular} = %{} |> SQSPollingJob.new(schedule_in: 3_600) |> Oban.insert()
    assert regular.state == "scheduled"

    assert {:ok, forced} = SQSPollingManager.poll_now()

    # Two distinct rows — different args (forced vs regular), so the
    # forced insert must never move the regular chain's own next tick.
    assert forced.id != regular.id
    assert forced.args == %{"forced" => true}

    reloaded_regular = Repo.get!(Oban.Job, regular.id)
    assert reloaded_regular.state == "scheduled"
    assert DateTime.compare(reloaded_regular.scheduled_at, regular.scheduled_at) == :eq
  end

  describe "integration_count/0" do
    test "0 with no working SES event source configured" do
      assert SQSPollingManager.integration_count() == 0
    end

    test "1 once an aws_ses integration + enabled send profile + a queue exist" do
      create_ses_profile()
      # integration_count/0 mirrors eligible?/0, which counts a queue to poll
      # as part of "a working SES event source".
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")

      assert SQSPollingManager.integration_count() == 1
    end

    test "0 with an integration + profile but no queue URL to poll" do
      create_ses_profile()

      assert SQSPollingManager.integration_count() == 0
    end
  end

  test "min_interval_ms/0 matches set_polling_interval/1's own floor" do
    assert SQSPollingManager.min_interval_ms() == 1_000
    assert {:error, _} = SQSPollingManager.set_polling_interval(999)
    assert {:ok, _} = SQSPollingManager.set_polling_interval(1_000)
  end
end
