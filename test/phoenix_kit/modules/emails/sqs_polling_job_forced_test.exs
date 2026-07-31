defmodule PhoenixKit.Modules.Emails.SQSPollingJobForcedTest do
  @moduledoc """
  `args: %{"forced" => true}` (inserted by `SQSPollingManager.poll_now/0`)
  bypasses the `sqs_polling_enabled` toggle for one cycle — mirroring
  `BrevoPollingJob`'s `forced?` handling. Without it, a manual poll while
  the toggle is off inserted a job that ran, hit `should_poll?/0`, and
  silently did nothing.

  The cycle is observed through its *configuration* error rather than a
  real SQS round trip: entering the cycle logs "Invalid configuration",
  while the disabled path never gets that far. The error is provoked with
  an out-of-range polling interval — the queue URL cannot be the trigger
  any more, because a missing queue URL now fails `eligible?/0` and the
  cycle is not entered at all.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_ses_events(true)
    # The toggle under test stays OFF for every case here.
    {:ok, _} = Emails.set_sqs_polling(false)
    # Eligible: a queue to poll plus an actively-configured SES sender.
    {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")
    create_ses_profile()
    # ...but deliberately misconfigured, so a cycle that IS entered fails
    # validate_configuration/1 and returns before any network call. Written
    # through Settings directly: set_sqs_polling_interval/1 rejects <1000.
    {:ok, _} = Settings.update_setting("sqs_polling_interval_ms", "500")
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

  test "a forced job runs its cycle even though the polling toggle is off" do
    refute Emails.sqs_polling_enabled?()

    log =
      capture_log(fn ->
        assert :ok = SQSPollingJob.perform(%Oban.Job{args: %{"forced" => true}})
      end)

    assert log =~ "Invalid configuration"
  end

  test "a regular (non-forced) job still no-ops while the toggle is off" do
    log =
      capture_log(fn ->
        assert :ok = SQSPollingJob.perform(%Oban.Job{args: %{}})
      end)

    refute log =~ "Invalid configuration"
  end

  test "a forced run does not resurrect the self-scheduling chain" do
    capture_log(fn ->
      assert :ok = SQSPollingJob.perform(%Oban.Job{args: %{"forced" => true}})
    end)

    # schedule_next_poll/1 re-checks should_poll?/0, which is still false.
    assert [] = worker_jobs(["available", "scheduled"])
  end

  test "forced does not bypass the system switch or the sender-aware gate" do
    {:ok, _} = Emails.disable_system()

    log =
      capture_log(fn ->
        assert :ok = SQSPollingJob.perform(%Oban.Job{args: %{"forced" => true}})
      end)

    refute log =~ "Invalid configuration"
  end
end
