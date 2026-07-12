defmodule PhoenixKit.Modules.Emails.MigrateLegacyTest do
  @moduledoc """
  `Emails.migrate_legacy/0` moves plaintext legacy AWS SES settings into
  an encrypted `aws_ses` Integrations connection (Stage B, B4).
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  describe "migrate_legacy/0" do
    test "moves legacy AWS SES settings into an encrypted Integrations connection" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")
      Settings.update_setting("aws_region", "eu-west-1")

      assert :ok = Emails.migrate_legacy()

      uuid = Settings.get_setting("emails_aws_integration_uuid")
      assert is_binary(uuid) and uuid != ""

      raw = Settings.get_json_setting_by_uuid(uuid)
      assert String.starts_with?(raw["secret_key"], "enc:v1:")

      assert {:ok, creds} = Integrations.get_credentials(uuid)
      assert creds["access_key"] == "AKIA_LEGACY"
      assert creds["secret_key"] == "SECRET_LEGACY"
      assert creds["aws_region"] == "eu-west-1"
    end

    test "defaults the region to us-east-1 when no legacy region is set" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      :ok = Emails.migrate_legacy()

      uuid = Settings.get_setting("emails_aws_integration_uuid")
      assert {:ok, %{"aws_region" => "us-east-1"}} = Integrations.get_credentials(uuid)
    end

    test "is idempotent — re-running does not create a second connection" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      :ok = Emails.migrate_legacy()
      uuid = Settings.get_setting("emails_aws_integration_uuid")

      :ok = Emails.migrate_legacy()

      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
      assert length(Integrations.list_connections("aws_ses")) == 1
    end

    test "no-ops when there are no legacy credentials" do
      assert :ok = Emails.migrate_legacy()
      assert Settings.get_setting("emails_aws_integration_uuid") in [nil, ""]
      assert Integrations.list_connections("aws_ses") == []
    end
  end
end
