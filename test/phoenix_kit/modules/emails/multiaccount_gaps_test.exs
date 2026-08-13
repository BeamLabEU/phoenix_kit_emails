defmodule PhoenixKit.Modules.Emails.MultiaccountGapsTest do
  @moduledoc """
  The paths a review found untested after the multi-account change landed:
  the legacy-settings seeding `migrate_legacy/0` performs, the event
  provenance `SQSProcessor` records, and the misconfigured-account branch that
  backs the whole polling cycle off.

  Each of these is a place where a silent regression looks exactly like
  "working fine" from the outside, which is why they get assertions rather
  than trust.
  """

  use PhoenixKitEmails.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Event
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.Repo

  setup do
    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  defp create_connection(opts \\ []) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    if Keyword.get(opts, :credentials, true) do
      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIATEST",
          "secret_key" => "secret",
          "aws_region" => "eu-north-1"
        })
    end

    uuid
  end

  defp create_profile(integration_uuid) do
    {:ok, _} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  ## --- migrate_legacy/0's seeding of aws_tracking:<uuid> ---

  describe "seeding the selected account's tracking row from the legacy settings" do
    test "copies every global pipeline setting onto the selected account" do
      uuid = create_connection()
      {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", uuid)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")
      {:ok, _} = Emails.set_sqs_dlq_url("https://sqs.example.com/legacy-dlq")
      {:ok, _} = Emails.set_sqs_queue_arn("arn:aws:sqs:eu-north-1:1:legacy")
      {:ok, _} = Emails.set_sns_topic_arn("arn:aws:sns:eu-north-1:1:legacy")
      {:ok, _} = Settings.update_setting("aws_ses_configuration_set", "legacy-set")

      assert :ok = Emails.migrate_legacy()

      tracking = Emails.get_aws_tracking(uuid)
      assert tracking.queue_url == "https://sqs.example.com/legacy"
      assert tracking.dlq_url == "https://sqs.example.com/legacy-dlq"
      assert tracking.queue_arn == "arn:aws:sqs:eu-north-1:1:legacy"
      assert tracking.sns_topic_arn == "arn:aws:sns:eu-north-1:1:legacy"
      assert tracking.configuration_set == "legacy-set"
    end

    test "never overwrites a row the operator has already edited" do
      uuid = create_connection()
      {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", uuid)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"queue_url" => "https://sqs.example.com/edited"})

      assert :ok = Emails.migrate_legacy()

      assert Emails.get_aws_tracking(uuid).queue_url == "https://sqs.example.com/edited"
    end

    test "is idempotent — a second run changes nothing" do
      uuid = create_connection()
      {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", uuid)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")

      assert :ok = Emails.migrate_legacy()
      first = Emails.get_aws_tracking(uuid)
      assert :ok = Emails.migrate_legacy()

      assert Emails.get_aws_tracking(uuid) == first
    end

    test "writes nothing when there is no selected account" do
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/legacy")

      assert :ok = Emails.migrate_legacy()

      assert Emails.list_aws_tracking_integration_uuids() == []
    end

    test "writes nothing when the selected account has no legacy settings to carry over" do
      # A fresh install that only ever picked a credentials source: an
      # all-nil row would make the legacy fallback unreachable for no gain.
      uuid = create_connection()
      {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", uuid)

      assert :ok = Emails.migrate_legacy()

      assert Emails.get_aws_tracking(uuid) == nil
    end
  end

  ## --- Event provenance kept in event_data ---

  describe "SES event provenance" do
    test "sendingAccountId, sourceArn and configurationSet are kept under _source" do
      event =
        delivery_event(
          %{
            "sendingAccountId" => "631259293366",
            "sourceArn" => "arn:aws:ses:eu-north-1:631259293366:identity/example.com"
          },
          %{"configurationSet" => "account-b-set"}
        )

      assert {:ok, _} = process(event)

      assert %{"_source" => source} = stored_event_data(event["mail"]["messageId"])
      assert source["sendingAccountId"] == "631259293366"
      assert source["sourceArn"] =~ "631259293366"
      assert source["configurationSet"] == "account-b-set"
    end

    test "the provider's own sub-object is preserved alongside the provenance" do
      event = delivery_event(%{"sendingAccountId" => "1"})

      assert {:ok, _} = process(event)

      data = stored_event_data(event["mail"]["messageId"])
      assert data["recipients"] == ["recipient@example.com"]
      assert data["timestamp"] == "2026-08-12T10:00:00.000Z"
    end

    test "an event with no provenance fields at all is stored untouched" do
      event = delivery_event()

      assert {:ok, _} = process(event)

      data = stored_event_data(event["mail"]["messageId"])
      refute Map.has_key?(data, "_source")
    end

    test "a Brevo-shaped event is not mutated — provenance is an SES envelope concept" do
      # BrevoEventNormalizer produces the same normalized shape with no
      # `mail.sendingAccountId` and no top-level configurationSet.
      event = delivery_event()

      assert {:ok, _} = process(event)

      assert stored_event_data(event["mail"]["messageId"]) == %{
               "timestamp" => "2026-08-12T10:00:00.000Z",
               "recipients" => ["recipient@example.com"]
             }
    end
  end

  ## --- The misconfigured-account backoff ---

  describe "a misconfigured account backs the cycle off" do
    test "an account with a queue but no resolvable credentials is misconfigured" do
      # Two accounts so the broken one cannot inherit the legacy credentials
      # (that fallback is only for the account the globals belong to).
      broken = create_connection(credentials: false)
      other = create_connection()
      create_profile(broken)
      create_profile(other)

      {:ok, _} =
        Emails.set_aws_tracking(broken, %{"queue_url" => "https://sqs.example.com/broken"})

      {:ok, _} = Emails.set_aws_tracking(other, %{"queue_url" => "https://sqs.example.com/other"})

      accounts = SQSPollingJob.pollable_accounts()
      broken_account = Enum.find(accounts, &(&1.integration_uuid == broken))

      assert broken_account, "the broken account must still be polled, not silently dropped"

      refute broken_account.inherits_legacy?,
             "with two accounts and no selection, neither may claim the global credentials"

      log =
        capture_log(fn ->
          assert :misconfigured =
                   SQSPollingJob.run_cycle([broken_account], Emails.get_sqs_config())
        end)

      assert log =~ "could not resolve credentials for integration #{broken}"
      assert log =~ "backing off"
    end

    test "a credential-less account that CAN claim the globals falls back instead of failing" do
      # The env-var / instance-profile deployment: the connection exists so a
      # SendProfile can point at it, but the keys live outside the database.
      uuid = create_connection(credentials: false)
      create_profile(uuid)
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"queue_url" => "https://sqs.example.com/only"})

      assert [account] = SQSPollingJob.pollable_accounts()
      assert account.inherits_legacy?, "the only active account may claim the global settings"

      # Resolving must NOT report :misconfigured; it hands ExAws an empty
      # config, which is how ExAws is told to resolve credentials itself.
      assert {:ok, []} = SQSPollingJob.resolve_aws_config(account)
    end
  end

  ## --- helpers ---

  defp process(event_data), do: SQSProcessor.process_email_event(event_data)

  # A real Log to attach the event to, so nothing here depends on the
  # placeholder-creation setting.
  defp delivery_event(mail_extra \\ %{}, top_extra \\ %{}) do
    message_id = "pk_#{System.unique_integer([:positive])}"

    {:ok, _log} =
      %Log{}
      |> Log.changeset(%{
        message_id: message_id,
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "aws_ses",
        status: "sent"
      })
      |> Repo.insert()

    Map.merge(
      %{
        "eventType" => "Delivery",
        "mail" => Map.merge(%{"messageId" => message_id}, mail_extra),
        "delivery" => %{
          "timestamp" => "2026-08-12T10:00:00.000Z",
          "recipients" => ["recipient@example.com"]
        }
      },
      top_extra
    )
  end

  defp stored_event_data(message_id) do
    Repo.one!(
      from(e in Event,
        join: l in Log,
        on: l.uuid == e.email_log_uuid,
        where: l.message_id == ^message_id,
        select: e.event_data
      )
    )
  end
end
