defmodule PhoenixKit.Modules.Emails.SupervisorBootTest do
  @moduledoc """
  P0: Brevo boot-starter symmetry with SES (spec §1.1). Exercises the two
  gate functions directly (public, `@doc false`), and `init/1`'s children
  shape, without spawning the supervisor's own async Task and racing its
  `enable_polling/0` call.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Supervisor, as: EmailsSupervisor
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp create_ses_profile do
    # has_sqs_configuration?/0 (the supervisor's own boot gate) checks the
    # queue URL setting directly — a separate condition from the
    # SendProfile/credentials below, which only satisfy the job's own
    # runtime sender-aware gate.
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

  describe "should_start_brevo_oban_polling?/0 — symmetric to should_start_oban_polling?/0" do
    test "false with nothing configured" do
      refute EmailsSupervisor.should_start_brevo_oban_polling?()
    end

    test "true with an active brevo_api profile and the toggle on" do
      create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      assert EmailsSupervisor.should_start_brevo_oban_polling?()
    end

    test "false when the polling toggle is off, even with an active profile" do
      create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(false)

      refute EmailsSupervisor.should_start_brevo_oban_polling?()
    end

    test "false when the toggle is on but no active brevo_api profile exists" do
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      refute EmailsSupervisor.should_start_brevo_oban_polling?()
    end

    test "a disabled brevo_api profile does not satisfy eligibility" do
      {:ok, %{uuid: integration_uuid}} =
        Integrations.add_connection("brevo_api", "Brevo disabled")

      {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

      {:ok, _} =
        SendProfiles.create_send_profile(%{
          name: "Disabled Brevo profile",
          integration_uuid: integration_uuid,
          provider_kind: "brevo_api",
          from_email: "sender@example.com",
          enabled: false
        })

      {:ok, _} = Emails.set_brevo_events_enabled(true)

      refute EmailsSupervisor.should_start_brevo_oban_polling?()
    end
  end

  describe "init/1 — the boot Task appears iff either gate is satisfied" do
    test "neither gate satisfied: no Task, just the credentials cache" do
      {:ok, {_flags, children}} = EmailsSupervisor.init([])

      refute Enum.any?(children, &task_child?/1)
    end

    test "SQS-only gate satisfied: the shared Task is present" do
      create_ses_profile()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)

      {:ok, {_flags, children}} = EmailsSupervisor.init([])

      assert Enum.count(children, &task_child?/1) == 1
    end

    test "Brevo-only gate satisfied: the shared Task is present" do
      create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      {:ok, {_flags, children}} = EmailsSupervisor.init([])

      assert Enum.count(children, &task_child?/1) == 1
    end

    test "both gates satisfied: still exactly ONE shared Task, not two" do
      create_ses_profile()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)

      create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(true)

      {:ok, {_flags, children}} = EmailsSupervisor.init([])

      assert Enum.count(children, &task_child?/1) == 1
    end
  end

  defp task_child?(%{start: {Task, :start_link, _}}), do: true
  defp task_child?(_), do: false
end
