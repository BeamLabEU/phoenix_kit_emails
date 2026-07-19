defmodule PhoenixKit.Modules.Emails.SQSPollingJobSenderAwareTest do
  @moduledoc """
  Sender-aware gate on `SQSPollingJob.should_poll?/0`, mirroring
  `BrevoPollingJob`'s: SQS credentials being *reachable* isn't the same
  as SES actually being the thing sending mail right now. Only tests the
  gate itself (`should_poll?/0` — public, `@doc false`, specifically so
  this doesn't need a real SQS/network round trip) — the receive/process
  cycle this gate wraps is unchanged and untested here.
  """

  # aws_configured?/0 reads through `Emails.aws_ses_credentials/0`'s TTL
  # cache (60s, keyed process-globally via `PhoenixKit.Cache`, not scoped
  # to a test's DB transaction) — under async: true a concurrent test's
  # freshly-created (and later rolled-back) integration can still leak
  # into this test's cached read. async: false + explicit invalidation
  # keeps each test's gate check honest.
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Settings

  setup do
    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_ses_events(true)
    {:ok, _} = Emails.set_sqs_polling(true)
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  defp create_ses_profile(opts \\ []) do
    enabled = Keyword.get(opts, :enabled, true)

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
        enabled: enabled
      })

    profile
  end

  test "no SendProfile and no legacy AWS credentials: should_poll?/0 is false" do
    refute SQSPollingJob.should_poll?()
  end

  test "an enabled aws_ses SendProfile: should_poll?/0 is true" do
    create_ses_profile()
    assert SQSPollingJob.should_poll?()
  end

  test "a disabled aws_ses SendProfile alone does not satisfy the gate" do
    create_ses_profile(enabled: false)
    refute SQSPollingJob.should_poll?()
  end

  test "legacy AWS credentials with no SendProfile at all: the explicit override still polls" do
    Settings.update_setting("aws_access_key_id", "AKIALEGACY")
    Settings.update_setting("aws_secret_access_key", "legacy-secret")

    assert SQSPollingJob.should_poll?()
  end

  test "the base flags still gate independently of sender configuration" do
    create_ses_profile()

    {:ok, _} = Emails.set_sqs_polling(false)
    refute SQSPollingJob.should_poll?()
  end
end
