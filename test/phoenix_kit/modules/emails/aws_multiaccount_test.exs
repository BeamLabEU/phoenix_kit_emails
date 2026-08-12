defmodule PhoenixKit.Modules.Emails.AwsMultiaccountTest do
  @moduledoc """
  The pure, network-free half of multi-account SES event tracking:

  - `AwsIntegrations` — which accounts count as active, and how their
    credentials resolve;
  - `Emails`' `aws_tracking:<uuid>` per-account settings and the
    `sqs_polling_excluded_integrations` opt-out;
  - `SQSPollingJob.configured_accounts/0` / `pollable_accounts/0` — the
    account resolution the polling cycle and the eligibility gate both run
    on, including the legacy single-queue fallbacks;
  - `SQSPollingManager`'s `accounts/0` / `toggle_account_polling/1` /
    `integration_count/0`.

  Nothing here touches SQS: `configured_accounts/0` and friends are public
  (`@doc false`) specifically so the resolution can be tested without a
  network round trip, the same rationale `should_poll?/0` carries.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.AwsIntegrations
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Settings

  setup do
    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  defp create_connection(opts \\ []) do
    name = Keyword.get(opts, :name, "SES #{System.unique_integer([:positive])}")

    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", name)

    unless Keyword.get(opts, :credentials, true) == false do
      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => Keyword.get(opts, :access_key, "AKIATEST"),
          "secret_key" => "secret",
          "aws_region" => Keyword.get(opts, :region, "eu-north-1")
        })
    end

    uuid
  end

  defp create_profile(integration_uuid, opts \\ []) do
    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: Keyword.get(opts, :provider_kind, "aws_ses"),
        from_email: "sender@example.com",
        enabled: Keyword.get(opts, :enabled, true)
      })

    profile
  end

  ## --- AwsIntegrations ---

  describe "AwsIntegrations.active_integration_uuids/0" do
    test "returns the integration behind every enabled aws_ses send profile, deduplicated" do
      uuid = create_connection()
      create_profile(uuid)
      create_profile(uuid)

      assert AwsIntegrations.active_integration_uuids() == [uuid]
    end

    test "ignores disabled profiles and other provider kinds" do
      disabled = create_connection()
      create_profile(disabled, enabled: false)

      {:ok, %{uuid: brevo_uuid}} = Integrations.add_connection("brevo_api", "Brevo")
      {:ok, _} = Integrations.save_setup(brevo_uuid, %{"api_key" => "k"})
      create_profile(brevo_uuid, provider_kind: "brevo_api")

      assert AwsIntegrations.active_integration_uuids() == []
    end
  end

  describe "AwsIntegrations.resolve_credentials/1" do
    test "returns the connection's own keys and region" do
      uuid = create_connection(region: "us-west-2", access_key: "AKIAONE")

      assert {:ok, creds} = AwsIntegrations.resolve_credentials(uuid)
      assert creds.access_key == "AKIAONE"
      assert creds.secret_key == "secret"
      assert creds.region == "us-west-2"
    end

    test "a connection with no credentials is an error, not a blank-key config" do
      uuid = create_connection(credentials: false)

      assert {:error, :missing_credentials} = AwsIntegrations.resolve_credentials(uuid)
    end

    test "different accounts resolve to different keys (the cache is keyed per account)" do
      one = create_connection(access_key: "AKIAONE")
      two = create_connection(access_key: "AKIATWO")

      assert {:ok, %{access_key: "AKIAONE"}} = AwsIntegrations.resolve_credentials(one)
      assert {:ok, %{access_key: "AKIATWO"}} = AwsIntegrations.resolve_credentials(two)
      # ...and again, now that both are memoized.
      assert {:ok, %{access_key: "AKIAONE"}} = AwsIntegrations.resolve_credentials(one)
    end
  end

  describe "AwsIntegrations.active_integrations_with_names/0" do
    test "pairs each active uuid with its connection name" do
      uuid = create_connection(name: "Production SES")
      create_profile(uuid)

      assert AwsIntegrations.active_integrations_with_names() == [{uuid, "Production SES"}]
    end
  end

  ## --- aws_tracking:<uuid> settings ---

  describe "aws_tracking settings" do
    test "round-trips the full field set" do
      attrs = %{
        "queue_url" => "https://sqs.eu-north-1.amazonaws.com/1/q",
        "dlq_url" => "https://sqs.eu-north-1.amazonaws.com/1/q-dlq",
        "queue_arn" => "arn:aws:sqs:eu-north-1:1:q",
        "sns_topic_arn" => "arn:aws:sns:eu-north-1:1:t",
        "configuration_set" => "acct-one-tracking",
        "region" => "eu-north-1"
      }

      assert {:ok, _} = Emails.set_aws_tracking("acct-1", attrs)

      tracking = Emails.get_aws_tracking("acct-1")
      assert tracking.queue_url == attrs["queue_url"]
      assert tracking.dlq_url == attrs["dlq_url"]
      assert tracking.queue_arn == attrs["queue_arn"]
      assert tracking.sns_topic_arn == attrs["sns_topic_arn"]
      assert tracking.configuration_set == "acct-one-tracking"
      assert tracking.region == "eu-north-1"
    end

    test "blank and missing values normalize to nil, unknown keys are dropped" do
      assert {:ok, _} =
               Emails.set_aws_tracking("acct-1", %{
                 "queue_url" => "  ",
                 "configuration_set" => "  set  ",
                 "not_a_field" => "x"
               })

      tracking = Emails.get_aws_tracking("acct-1")
      assert tracking.queue_url == nil
      assert tracking.dlq_url == nil
      assert tracking.configuration_set == "set"
      refute Map.has_key?(tracking, :not_a_field)
    end

    test "atom keys are accepted too" do
      assert {:ok, _} = Emails.set_aws_tracking("acct-1", %{queue_url: "https://q"})
      assert Emails.get_aws_tracking("acct-1").queue_url == "https://q"
    end

    test "an account with no settings reads as nil — the legacy-fallback signal" do
      assert Emails.get_aws_tracking("never-configured") == nil
    end

    test "list/delete cover exactly the configured accounts" do
      {:ok, _} = Emails.set_aws_tracking("acct-1", %{"queue_url" => "https://one"})
      {:ok, _} = Emails.set_aws_tracking("acct-2", %{"queue_url" => "https://two"})

      assert Enum.sort(Emails.list_aws_tracking_integration_uuids()) == ["acct-1", "acct-2"]

      Emails.delete_aws_tracking("acct-1")

      assert Emails.list_aws_tracking_integration_uuids() == ["acct-2"]
      assert Emails.get_aws_tracking("acct-1") == nil
    end
  end

  describe "sqs_polling_excluded_integrations" do
    test "defaults to empty and round-trips a list" do
      assert Emails.get_sqs_polling_excluded_integrations() == []

      {:ok, _} = Emails.set_sqs_polling_excluded_integrations(["a", "b"])
      assert Emails.get_sqs_polling_excluded_integrations() == ["a", "b"]

      {:ok, _} = Emails.set_sqs_polling_excluded_integrations([])
      assert Emails.get_sqs_polling_excluded_integrations() == []
    end
  end

  ## --- Account resolution ---

  describe "SQSPollingJob.configured_accounts/0" do
    test "no send profiles: the legacy single-queue account, from the global settings" do
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")

      assert [%{integration_uuid: nil, queue_url: "https://sqs.example.com/legacy"}] =
               SQSPollingJob.configured_accounts()
    end

    test "no send profiles and no global queue: nothing to poll" do
      assert SQSPollingJob.configured_accounts() == []
    end

    test "an account with its own aws_tracking uses its own queue and region" do
      uuid = create_connection()
      create_profile(uuid)

      {:ok, _} =
        Emails.set_aws_tracking(uuid, %{
          "queue_url" => "https://sqs.example.com/own",
          "region" => "us-west-2"
        })

      assert [account] = SQSPollingJob.configured_accounts()
      assert account.integration_uuid == uuid
      assert account.queue_url == "https://sqs.example.com/own"
      assert account.region == "us-west-2"
    end

    test "the ONLY active account inherits the global queue when it has no settings of its own" do
      uuid = create_connection()
      create_profile(uuid)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")

      assert [%{integration_uuid: ^uuid, queue_url: "https://sqs.example.com/legacy"}] =
               SQSPollingJob.configured_accounts()
    end

    test "with two unattributed accounts the global queue is inherited by neither" do
      one = create_connection()
      two = create_connection()
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")

      assert SQSPollingJob.configured_accounts() == []
    end

    test "...unless one of them is the account emails_aws_integration_uuid selects" do
      one = create_connection()
      two = create_connection()
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")
      {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", two)

      assert [%{integration_uuid: ^two, queue_url: "https://sqs.example.com/legacy"}] =
               SQSPollingJob.configured_accounts()
    end

    test "an account without any queue is skipped, the configured one still polls" do
      one = create_connection()
      two = create_connection()
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_aws_tracking(one, %{"queue_url" => "https://sqs.example.com/one"})

      assert [%{integration_uuid: ^one}] = SQSPollingJob.configured_accounts()
    end
  end

  describe "SQSPollingJob.pollable_accounts/0" do
    test "drops the accounts the operator opted out of, but configured_accounts/0 keeps them" do
      one = create_connection()
      two = create_connection()
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_aws_tracking(one, %{"queue_url" => "https://sqs.example.com/one"})
      {:ok, _} = Emails.set_aws_tracking(two, %{"queue_url" => "https://sqs.example.com/two"})
      {:ok, _} = Emails.set_sqs_polling_excluded_integrations([two])

      assert [%{integration_uuid: ^one}] = SQSPollingJob.pollable_accounts()

      # The eligibility gate deliberately ignores the opt-out, so opting
      # every account out pauses polling instead of tearing the chain down.
      assert length(SQSPollingJob.configured_accounts()) == 2
    end

    test "the legacy account has no uuid and so can never be excluded" do
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")
      {:ok, _} = Emails.set_sqs_polling_excluded_integrations(["anything"])

      assert [%{integration_uuid: nil}] = SQSPollingJob.pollable_accounts()
    end
  end

  ## --- Manager surface the admin panel reads ---

  describe "SQSPollingManager multi-account callbacks" do
    test "accounts/0 lists every active account with its opt-out state" do
      one = create_connection(name: "Account One")
      two = create_connection(name: "Account Two")
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_sqs_polling_excluded_integrations([two])

      accounts = Enum.sort_by(SQSPollingManager.accounts(), fn {_uuid, name, _} -> name end)

      assert [{^one, "Account One", true}, {^two, "Account Two", false}] = accounts
    end

    test "toggle_account_polling/1 flips an active account in and out of the exclusion list" do
      uuid = create_connection()
      create_profile(uuid)

      assert {:ok, _} = SQSPollingManager.toggle_account_polling(uuid)
      assert Emails.get_sqs_polling_excluded_integrations() == [uuid]

      assert {:ok, _} = SQSPollingManager.toggle_account_polling(uuid)
      assert Emails.get_sqs_polling_excluded_integrations() == []
    end

    test "toggle_account_polling/1 ignores a uuid that is not an active account" do
      assert {:ok, :ignored} = SQSPollingManager.toggle_account_polling("forged-uuid")
      assert Emails.get_sqs_polling_excluded_integrations() == []
    end

    test "integration_count/0 counts the accounts that have somewhere to poll" do
      one = create_connection()
      two = create_connection()
      create_profile(one)
      create_profile(two)
      {:ok, _} = Emails.set_aws_tracking(one, %{"queue_url" => "https://sqs.example.com/one"})

      # Only `one` has a queue — mirrors eligible?/0, which does not consider
      # a queue-less account a working event source.
      assert SQSPollingManager.integration_count() == 1

      {:ok, _} = Emails.set_aws_tracking(two, %{"queue_url" => "https://sqs.example.com/two"})
      assert SQSPollingManager.integration_count() == 2
    end

    test "integration_count/0 still reports the legacy single-queue deployment as one" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")
      {:ok, _} = Settings.update_setting("aws_access_key_id", "AKIALEGACY")
      {:ok, _} = Settings.update_setting("aws_secret_access_key", "legacy-secret")
      Emails.invalidate_aws_credentials_cache()

      assert SQSPollingManager.integration_count() == 1
    end
  end
end
