defmodule PhoenixKit.Modules.Emails.EventTrackerReconcilerLifecycleTest do
  @moduledoc """
  Lifecycle triggers (spec §8) against the REAL SES/Brevo trackers (not
  `FakeEventTracker`): adding an integration starts the matching chain,
  removing the last one stops it, and toggling reconciles. This is what
  actually fixes spec §1.1/§1.2 — the invariant mechanics themselves are
  covered more exhaustively in `EventTrackerReconcilerTest`.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp worker_jobs(worker) do
    worker_name = inspect(worker)

    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker_name and j.state in ["available", "scheduled"]
      )
    )
  end

  defp create_ses_profile do
    {:ok, _} =
      Settings.update_setting(
        "aws_sqs_queue_url",
        "https://sqs.eu-north-1.amazonaws.com/123456789/test-queue"
      )

    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "secret"
      })

    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    profile
  end

  defp create_brevo_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: true
      })

    profile
  end

  describe "SES tracker" do
    test "adding an eligible SendProfile + toggling on, then reconciling, starts the chain" do
      create_ses_profile()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)

      assert worker_jobs(SQSPollingJob) == []

      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(SQSPollingManager)
      assert [_one] = worker_jobs(SQSPollingJob)
    end

    test "with nothing configured, reconcile is a no-op — no chain starts" do
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(SQSPollingManager)
      assert worker_jobs(SQSPollingJob) == []
    end

    test "toggling sqs_polling_enabled off then reconciling stops an existing chain" do
      create_ses_profile()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(SQSPollingManager)
      assert [_one] = worker_jobs(SQSPollingJob)

      {:ok, _} = Emails.set_sqs_polling(false)
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(SQSPollingManager)
      assert worker_jobs(SQSPollingJob) == []
    end
  end

  describe "Brevo tracker" do
    test "removing the last active integration, then reconciling, stops the chain" do
      profile = create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(BrevoPollingManager)
      assert [_one] = worker_jobs(BrevoPollingJob)

      # "Removing the last integration" == disabling the only active profile
      # (BrevoIntegrations.active_integration_uuids/0's own definition of
      # "active" — an *enabled* brevo_api SendProfile).
      {:ok, _} = SendProfiles.update_send_profile(profile, %{enabled: false})

      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(BrevoPollingManager)
      assert worker_jobs(BrevoPollingJob) == []
    end

    test "adding the first active integration, then reconciling, starts the chain" do
      {:ok, _} = Emails.set_brevo_events_enabled(true)
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(BrevoPollingManager)
      assert worker_jobs(BrevoPollingJob) == []

      create_brevo_profile()

      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(BrevoPollingManager)
      assert [_one] = worker_jobs(BrevoPollingJob)
    end
  end
end
