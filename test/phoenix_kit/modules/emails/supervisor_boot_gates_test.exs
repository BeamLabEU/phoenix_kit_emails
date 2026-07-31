defmodule PhoenixKit.Modules.Emails.SupervisorBootGatesTest do
  @moduledoc """
  Boot gates for re-seeding the SQS / Brevo self-scheduling chains on
  supervisor start. Exercised as pure predicates (no real Task/Oban wait)
  so a dead chain with the toggle still on is detectable without booting
  the full supervision tree.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Supervisor

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  describe "should_start_sqs_polling?/0" do
    test "false until SES events, the SQS toggle, and a queue URL are all set" do
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_ses_events(true)
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_sqs_polling(true)
      refute Supervisor.should_start_sqs_polling?()

      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")
      assert Supervisor.should_start_sqs_polling?()
    end

    test "false when the system itself is disabled" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")
      {:ok, _} = Emails.disable_system()

      refute Supervisor.should_start_sqs_polling?()
    end
  end

  describe "should_start_brevo_polling?/0" do
    test "true when the system is on and brevo_events_enabled is on" do
      refute Supervisor.should_start_brevo_polling?()

      {:ok, _} = Emails.set_brevo_events_enabled(true)
      assert Supervisor.should_start_brevo_polling?()
    end

    test "false when the system itself is disabled even if the Brevo toggle is on" do
      {:ok, _} = Emails.set_brevo_events_enabled(true)
      {:ok, _} = Emails.disable_system()

      refute Supervisor.should_start_brevo_polling?()
    end

    test "does not require active Brevo profiles (job no-ops each cycle)" do
      {:ok, _} = Emails.set_brevo_events_enabled(true)
      # No SendProfile created — boot still re-seeds the chain so a profile
      # added later is picked up without a manual re-toggle.
      assert Supervisor.should_start_brevo_polling?()
    end
  end
end
