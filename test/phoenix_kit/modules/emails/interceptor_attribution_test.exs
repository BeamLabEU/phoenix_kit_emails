defmodule PhoenixKit.Modules.Emails.InterceptorAttributionTest do
  @moduledoc """
  Send-path account attribution: which integration a log is stamped with, and
  — the part with teeth — which SES configuration set actually goes out on the
  wire.

  The bug this file exists for: the configuration set was resolved per-account
  when BUILDING THE LOG, but `add_tracking_headers/3` re-derived it from the
  untouched opts, so the database recorded account B's configuration set while
  `X-SES-CONFIGURATION-SET` carried the global one. Every assertion here that
  inspects a real header instead of the log row is deliberate: a test that only
  checked `log.configuration_set` passed throughout that bug's lifetime.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Swoosh.Email

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.Repo

  setup do
    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Settings.update_setting("aws_ses_configuration_set", "global-set")
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  defp connection(provider \\ "aws_ses") do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection(provider, "#{provider} #{System.unique_integer([:positive])}")

    credentials =
      if provider == "aws_ses" do
        %{"access_key" => "AKIATEST", "secret_key" => "secret", "aws_region" => "eu-north-1"}
      else
        %{"api_key" => "test-key"}
      end

    {:ok, _} = Integrations.save_setup(uuid, credentials)
    uuid
  end

  defp send_profile(integration_uuid, provider_kind \\ "aws_ses") do
    {:ok, _} =
      SendProfiles.create_send_profile(%{
        name: "profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: provider_kind,
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  defp make_default(uuid) do
    {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)
    Emails.invalidate_aws_credentials_cache()
    :ok
  end

  defp mail do
    new()
    |> to("recipient@example.com")
    |> from("sender@example.com")
    |> subject("Attribution test")
    |> text_body("body")
  end

  defp intercept(opts \\ []) do
    sent = Interceptor.intercept_before_send(mail(), opts)
    log = Repo.get_by!(Log, message_id: sent.headers["X-PhoenixKit-Message-Id"])
    {sent, log}
  end

  ## --- The integration_uuid stamp ---

  describe "integration_uuid stamp" do
    test "is taken from the operator's default send integration" do
      uuid = connection()
      make_default(uuid)

      {_sent, log} = intercept()

      assert log.integration_uuid == uuid
    end

    test "an explicit :integration_uuid opt wins over the default" do
      default = connection()
      explicit = connection()
      make_default(default)

      {_sent, log} = intercept(integration_uuid: explicit)

      assert log.integration_uuid == explicit
    end

    test "is left unstamped when :provider contradicts the default integration" do
      # Core stamps :provider from the credentials of the connection that
      # really sent the message. A mismatch proves the default account is not
      # the sender, so an unstamped row beats a wrong one.
      uuid = connection("aws_ses")
      make_default(uuid)

      {_sent, log} = intercept(provider: "brevo_api")

      assert log.integration_uuid == nil
    end

    test "is stamped when :provider agrees with the default integration" do
      uuid = connection("aws_ses")
      make_default(uuid)

      {_sent, log} = intercept(provider: "aws_ses")

      assert log.integration_uuid == uuid
    end

    test "is nil when no default send integration is configured" do
      {_sent, log} = intercept()

      assert log.integration_uuid == nil
    end

    test "is nil when the default integration has no credentials (not 'connected')" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "Never set up")
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)
      Emails.invalidate_aws_credentials_cache()

      {_sent, log} = intercept()

      assert log.integration_uuid == nil
    end
  end

  ## --- The configuration set actually put on the wire ---

  describe "SES configuration set on the wire" do
    test "the header always matches what the log recorded" do
      uuid = connection()
      send_profile(uuid)
      make_default(uuid)
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"configuration_set" => "account-a-set"})
      Emails.invalidate_aws_credentials_cache()

      {sent, log} = intercept()

      assert sent.headers["X-SES-CONFIGURATION-SET"] == log.configuration_set
    end

    test "a single active SES account puts ITS OWN configuration set on the message" do
      uuid = connection()
      send_profile(uuid)
      make_default(uuid)
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"configuration_set" => "account-a-set"})
      Emails.invalidate_aws_credentials_cache()

      {sent, log} = intercept()

      assert sent.headers["X-SES-CONFIGURATION-SET"] == "account-a-set"
      assert log.configuration_set == "account-a-set"
    end

    test "an explicitly routed send carries THAT account's configuration set, not the default's" do
      # The multi-account case the whole feature is for: two active SES
      # accounts, a send explicitly routed through the non-default one.
      account_a = connection()
      account_b = connection()
      send_profile(account_a)
      send_profile(account_b)
      make_default(account_a)

      {:ok, _} = Emails.set_aws_tracking(account_a, %{"configuration_set" => "account-a-set"})
      {:ok, _} = Emails.set_aws_tracking(account_b, %{"configuration_set" => "account-b-set"})
      Emails.invalidate_aws_credentials_cache()

      {sent, log} = intercept(integration_uuid: account_b)

      assert sent.headers["X-SES-CONFIGURATION-SET"] == "account-b-set"
      assert log.configuration_set == "account-b-set"
      assert log.integration_uuid == account_b
    end

    test "an INFERRED account among several does NOT get a per-account set" do
      # The inference cannot distinguish "routed through the default" from
      # "routed through the other account of the same kind". A wrong
      # configuration set is an outright SES send failure, so with more than
      # one active account the global name is used until the caller says which
      # account it is.
      account_a = connection()
      account_b = connection()
      send_profile(account_a)
      send_profile(account_b)
      make_default(account_a)

      {:ok, _} = Emails.set_aws_tracking(account_a, %{"configuration_set" => "account-a-set"})
      Emails.invalidate_aws_credentials_cache()

      {sent, log} = intercept()

      assert sent.headers["X-SES-CONFIGURATION-SET"] == "global-set"
      assert log.configuration_set == "global-set"
      # ...the stamp itself is still recorded: a possibly-wrong index is
      # correctable, a wrong header is a failed send.
      assert log.integration_uuid == account_a
    end

    test "an explicit :configuration_set opt still overrides everything" do
      uuid = connection()
      send_profile(uuid)
      make_default(uuid)
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"configuration_set" => "account-a-set"})
      Emails.invalidate_aws_credentials_cache()

      {sent, _log} = intercept(configuration_set: "caller-set")

      assert sent.headers["X-SES-CONFIGURATION-SET"] == "caller-set"
    end

    test "falls back to the global setting when the account has no configuration set" do
      uuid = connection()
      send_profile(uuid)
      make_default(uuid)
      {:ok, _} = Emails.set_aws_tracking(uuid, %{"queue_url" => "https://sqs.example.com/q"})
      Emails.invalidate_aws_credentials_cache()

      {sent, _log} = intercept()

      assert sent.headers["X-SES-CONFIGURATION-SET"] == "global-set"
    end
  end

  ## --- build_ses_headers/2 called directly ---

  describe "build_ses_headers/2" do
    test "reads the configuration set back off the log when opts carry none" do
      log = %Log{
        uuid: Ecto.UUID.generate(),
        message_id: "pk_direct",
        configuration_set: "stored-on-the-log"
      }

      assert %{"X-SES-CONFIGURATION-SET" => "stored-on-the-log"} =
               Interceptor.build_ses_headers(log, [])
    end

    test "emits no header at all when neither opts nor the log carry one" do
      log = %Log{uuid: Ecto.UUID.generate(), message_id: "pk_direct", configuration_set: "  "}

      refute Map.has_key?(Interceptor.build_ses_headers(log, []), "X-SES-CONFIGURATION-SET")
    end
  end

  ## --- enrich_send_opts/1 ---

  describe "enrich_send_opts/1" do
    test "is idempotent — a second pass does not re-resolve or change anything" do
      uuid = connection()
      make_default(uuid)

      once = Interceptor.enrich_send_opts([])
      twice = Interceptor.enrich_send_opts(once)

      assert Keyword.get(once, :integration_uuid) == uuid
      assert twice == once
    end
  end
end
