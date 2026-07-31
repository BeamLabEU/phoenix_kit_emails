defmodule PhoenixKit.Modules.Emails.SupervisorBootGatesTest do
  @moduledoc """
  Boot gates for re-seeding the SQS / Brevo self-scheduling chains on
  supervisor start. Exercised as pure predicates (no real Task/Oban wait)
  so a dead chain with the toggle still on is detectable without booting
  the full supervision tree.

  Both predicates delegate to `EventTracker.should_run?/1`, the same gate
  boot's `EventTrackerReconciler.reconcile/0` applies per tracker — so what
  is asserted here is what boot does, not a second hand-written copy of the
  rule that can drift from it.
  """

  # aws_configured?/0 reads through a process-global TTL cache that is not
  # scoped to a test's DB transaction, so under async: true a concurrent
  # test's rolled-back integration could leak into these gate checks.
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Supervisor

  setup do
    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  describe "should_start_sqs_polling?/0" do
    test "false until SES events, a sender, the SQS toggle and a queue URL are all set" do
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_ses_events(true)
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_sqs_polling(true)
      refute Supervisor.should_start_sqs_polling?()

      # Sender-aware gate: reachable SQS credentials are not the same as SES
      # actually being what sends mail right now.
      create_ses_profile()
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")
      assert Supervisor.should_start_sqs_polling?()
    end

    test "false with everything else set but no queue URL to poll" do
      # Regression guard: a chain seeded in this state cannot do anything
      # except log "SQS queue URL not configured" on its misconfig backoff
      # forever, while the admin panel — seeing live jobs — calls it
      # :active. Without the queue URL the tracker is :idle_no_integration.
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      create_ses_profile()

      refute Supervisor.should_start_sqs_polling?()
    end

    test "false when the system itself is disabled" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      create_ses_profile()
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")
      {:ok, _} = Emails.disable_system()

      refute Supervisor.should_start_sqs_polling?()
    end
  end

  describe "should_start_brevo_polling?/0" do
    test "true when the system is on, the toggle is on and an integration is active" do
      refute Supervisor.should_start_brevo_polling?()

      {:ok, _} = Emails.set_brevo_events_enabled(true)
      refute Supervisor.should_start_brevo_polling?()

      create_brevo_profile()
      assert Supervisor.should_start_brevo_polling?()
    end

    test "false when the system itself is disabled even if the Brevo toggle is on" do
      {:ok, _} = Emails.set_brevo_events_enabled(true)
      create_brevo_profile()
      {:ok, _} = Emails.disable_system()

      refute Supervisor.should_start_brevo_polling?()
    end

    test "the toggle alone does not seed a chain with no active Brevo profile" do
      # Changed deliberately from "boot seeds it anyway so a profile added
      # later is picked up": with the reconcile Cron running, a profile added
      # later is picked up within one tick either way, so there is no reason
      # to run a chain that can only no-op. It also keeps the panel honest —
      # this state reads :idle_no_integration rather than :active.
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      refute Supervisor.should_start_brevo_polling?()
    end
  end

  defp create_ses_profile do
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
end
