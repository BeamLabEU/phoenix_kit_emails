defmodule PhoenixKit.Modules.Emails.CodeReviewIntegrationTest do
  @moduledoc """
  Integration regression tests for the 0.10.0+ review fixes that need the
  database or a router:

  - SQS path dispatches real SES `DeliveryDelay` / `Rendering Failure` events
    (was `:unknown_event_type` → poison-message redelivery loop).
  - Webhook rejects malformed SNS `Message` JSON and bad `Timestamp` shapes
    with 400, not a 500 crash; a far-future timestamp is rejected.
  - Export routes dispatch to real controller actions (was a 500 on a
    nonexistent `:export` action) and serve csv/json with a 400 on anything
    else, once the module-permission plug passes.
  - `RateLimiter.check_limits/1` tolerates a nil recipient and the per-recipient
    counter is case-insensitive (matches the blocklist's downcasing).
  - `Metrics.get_dashboard_data/1` / `Emails.get_system_stats/1` with an
    unknown period return defaults instead of `CaseClauseError`.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Metrics
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKit.Modules.Emails.Web.ExportController
  alias PhoenixKit.Modules.Emails.Web.Routes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  defmodule TestRouter do
    use Phoenix.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(Plug.Session, store: :cookie, key: "_test", signing_salt: "test_salt")
      plug(:fetch_session)
      plug(:fetch_flash)
    end

    pipeline :phoenix_kit_admin_only do
      plug(:accepts, ["html"])
    end

    Code.eval_quoted(Routes.generate("/phoenix_kit"), [], __ENV__)
  end

  setup do
    {:ok, _} = Emails.enable_system()
    Settings.update_boolean_setting("webhook_verify_sns_signature", false)
    Settings.update_boolean_setting("webhook_check_aws_ip", false)
    Settings.update_boolean_setting("webhook_rate_limit_enabled", false)
    # Make "emails" appear in `Permissions.enabled_module_keys/0` so the
    # export controller's module-permission plug can pass in this bare router
    # (in a host app the registry runs and discovery registers the module at
    # boot; the test app does not start it). The GenServer is linked to the
    # test process, so it dies with the test — nothing to stop.
    unless GenServer.whereis(PhoenixKit.ModuleRegistry) do
      PhoenixKit.ModuleRegistry.start_link()
    end

    PhoenixKit.ModuleRegistry.register(PhoenixKit.Modules.Emails)

    on_exit(fn ->
      if GenServer.whereis(PhoenixKit.ModuleRegistry) do
        PhoenixKit.ModuleRegistry.unregister(PhoenixKit.Modules.Emails)
      end
    end)

    :ok
  end

  defp post_webhook(params) do
    Plug.Test.conn(:post, "/phoenix_kit/webhooks/ses")
    |> Map.put(:params, params)
    |> TestRouter.call(TestRouter.init([]))
  end

  defp get_export(path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> TestRouter.call(TestRouter.init([]))
  end

  # A scope holding the wildcard superadmin key passes
  # `Scope.has_module_access?/2` for any module key, and the setup's
  # `Emails.enable_system()` puts "emails" in `Permissions.enabled_module_keys/0`.
  defp get_export_as_admin(path) do
    scope = %Scope{cached_permissions: MapSet.new(["*"])}

    Plug.Test.conn(:get, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Map.put(:assigns, %{phoenix_kit_current_scope: scope})
    |> TestRouter.call(TestRouter.init([]))
  end

  defp valid_timestamp, do: DateTime.to_iso8601(DateTime.utc_now())

  ## --- SQS event-type normalization ---

  describe "SQSProcessor dispatches real SES event types" do
    test "DeliveryDelay is not refused as :unknown_event_type" do
      event = %{
        "eventType" => "DeliveryDelay",
        "mail" => %{"messageId" => "msg-nonexistent-#{System.unique_integer([:positive])}"}
      }

      result = SQSProcessor.process_email_event(event)
      refute match?({:error, {:unknown_event_type, _}}, result)
    end

    test "Rendering Failure is not refused as :unknown_event_type" do
      event = %{
        "eventType" => "Rendering Failure",
        "mail" => %{"messageId" => "msg-nonexistent-#{System.unique_integer([:positive])}"},
        "failure" => %{"errorMessage" => "template error"}
      }

      result = SQSProcessor.process_email_event(event)
      refute match?({:error, {:unknown_event_type, _}}, result)
    end

    test "a non-binary eventType does not raise" do
      event = %{
        "eventType" => 123,
        "mail" => %{"messageId" => "msg-x-#{System.unique_integer([:positive])}"}
      }

      result = SQSProcessor.process_email_event(event)
      refute match?({:error, {:unknown_event_type, "123"}}, result)
    end
  end

  ## --- Webhook payload hardening ---

  describe "webhook rejects malformed payloads with 400, not 500" do
    test "a Message that decodes to a JSON array is :invalid_message" do
      conn =
        post_webhook(%{
          "Type" => "Notification",
          "Message" => "[1,2,3]",
          "Timestamp" => valid_timestamp()
        })

      assert conn.status == 400
    end

    test "a Message that is not JSON is :invalid_json" do
      conn =
        post_webhook(%{
          "Type" => "Notification",
          "Message" => "not json{",
          "Timestamp" => valid_timestamp()
        })

      assert conn.status == 400
    end

    test "a non-binary Timestamp is rejected, not a crash" do
      conn =
        post_webhook(%{
          "Type" => "Notification",
          "Message" => "{}",
          "Timestamp" => 123
        })

      assert conn.status == 400
    end

    test "a far-future Timestamp is rejected by the replay window" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      conn =
        post_webhook(%{
          "Type" => "Notification",
          "Message" => "{}",
          "Timestamp" => future
        })

      assert conn.status == 400
    end
  end

  ## --- Export routes dispatch to real actions ---

  describe "export routes" do
    test "logs export does not 500 on a missing action (redirects unauthenticated to /admin)" do
      conn = get_export("/phoenix_kit/emails/export/logs/csv")
      # No admin scope in this bare router -> the module-permission plug
      # redirects. The point is it is NOT a 500 (UndefinedFunctionError on a
      # nonexistent :export action).
      refute conn.status == 500
      assert conn.status in [302, 303]
    end

    test "with module access, logs export serves csv and json and 400s on anything else" do
      Code.ensure_loaded!(ExportController)
      assert function_exported?(ExportController, :export_logs, 2)

      csv = get_export_as_admin("/phoenix_kit/emails/export/logs/csv")
      assert csv.status == 200
      assert csv.resp_headers |> List.keyfind("content-type", 0) |> elem(1) =~ "text/csv"

      json = get_export_as_admin("/phoenix_kit/emails/export/logs/json")
      assert json.status == 200
      assert json.resp_headers |> List.keyfind("content-type", 0) |> elem(1) =~ "application/json"
      assert JSON.decode!(json.resp_body) == []

      bad = get_export_as_admin("/phoenix_kit/emails/export/logs/xml")
      assert bad.status == 400
    end

    test "blocklist and metrics exports serve 200 with module access" do
      assert get_export_as_admin("/phoenix_kit/emails/export/blocklist/csv").status == 200

      metrics_json = get_export_as_admin("/phoenix_kit/emails/export/metrics/json")
      assert metrics_json.status == 200
      assert is_map(JSON.decode!(metrics_json.resp_body))

      # The CSV generator used to crash on the summary scalars (Access.get on
      # a float) — it must serve a real table now.
      metrics_csv = get_export_as_admin("/phoenix_kit/emails/export/metrics/csv")
      assert metrics_csv.status == 200
      assert metrics_csv.resp_body =~ "Metric,Value"
      assert metrics_csv.resp_body =~ "bounce_rate"
    end

    test "email details export redirects (not 500) on an unknown id" do
      conn =
        get_export_as_admin(
          "/phoenix_kit/emails/export/email/00000000-0000-0000-0000-000000000000/csv"
        )

      refute conn.status == 500
      assert conn.status in [302, 303]
    end
  end

  ## --- Rate limiter ---

  describe "RateLimiter.check_limits/1" do
    test "a nil recipient/sender does not raise and returns :ok" do
      assert RateLimiter.check_limits(%{to: nil, from: nil}) == :ok
      assert RateLimiter.check_recipient_limit(nil) == :ok
      assert RateLimiter.check_sender_limit(nil) == :ok
    end

    test "the per-recipient counter is case-insensitive (matches the blocklist)" do
      Settings.update_setting_with_module("email_rate_limit_per_recipient", "1", "email_system")

      {:ok, _log} =
        Log.create_log(%{
          message_id: "msg-case-#{System.unique_integer([:positive])}",
          to: "Mixed.Case@Example.com",
          from: "sender@example.com",
          provider: "test",
          status: "sent",
          sent_at: DateTime.utc_now()
        })

      # Same address, different case: must count toward the same limit.
      assert RateLimiter.check_recipient_limit("mixed.case@example.com") ==
               {:blocked, :recipient_limit}

      assert RateLimiter.check_recipient_limit("MIXED.CASE@EXAMPLE.COM") ==
               {:blocked, :recipient_limit}
    end
  end

  ## --- Metrics period fallback ---

  describe "Metrics.get_dashboard_data/1 with an unknown period" do
    test "returns a map with empty defaults instead of CaseClauseError" do
      assert %{} = map = Metrics.get_dashboard_data(:bogus_period)
      assert is_map(map.overview) or map.overview == %{}
    end

    test "Emails.get_system_stats/1 and Metrics.get_metric_alerts/1 fall back too" do
      assert %{} = stats = Emails.get_system_stats(:bogus_period)
      assert is_map(stats)
      assert is_list(Metrics.get_metric_alerts(:bogus_period))
    end
  end
end
