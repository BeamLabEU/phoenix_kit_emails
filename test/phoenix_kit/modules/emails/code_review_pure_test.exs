defmodule PhoenixKit.Modules.Emails.CodeReviewPureTest do
  @moduledoc """
  Pure (no-database) regression tests for the 0.10.0+ review fixes:

  - `Event.normalize_event_type/1` is public and normalizes the SES spellings
    (`"DeliveryDelay"`, `"Rendering Failure"`) the SQS path used to miss, and
    never raises on a non-binary.
  - The export `Paths` helpers build root-scoped (no locale) URLs that match the
    routes core mounts, and the export controller exposes the actions the
    routes dispatch to (a missing action was a 500 on every export request).
  - `TemplateExport.files_for/2` refuses a template name that would escape the
    export directory (path traversal via a legacy `name` column).
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Event
  alias PhoenixKit.Modules.Emails.Paths
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Web.ExportController
  alias PhoenixKit.Utils.Routes

  describe "Event.normalize_event_type/1" do
    test "maps the real SES spellings to internal types" do
      assert Event.normalize_event_type("Bounce") == "bounce"
      assert Event.normalize_event_type("Delivery") == "delivery"
      assert Event.normalize_event_type("DeliveryDelay") == "delivery_delay"
      assert Event.normalize_event_type("Rendering Failure") == "rendering_failure"
      assert Event.normalize_event_type("Subscription") == "subscription"
    end

    test "unknown and non-binary become \"unknown\" without raising" do
      assert Event.normalize_event_type("SomethingNew") == "unknown"
      assert Event.normalize_event_type(123) == "unknown"
      assert Event.normalize_event_type(nil) == "unknown"
      assert Event.normalize_event_type(%{"x" => 1}) == "unknown"
    end
  end

  describe "Paths export helpers" do
    test "build root-scoped (locale-free) URLs that match the mounted routes" do
      assert Paths.export_logs("csv") == Routes.path("/emails/export/logs/csv", locale: :none)

      assert Paths.export_metrics("json") ==
               Routes.path("/emails/export/metrics/json", locale: :none)

      assert Paths.export_blocklist("csv") ==
               Routes.path("/emails/export/blocklist/csv", locale: :none)

      assert Paths.export_email("abc", "csv") ==
               Routes.path("/emails/export/email/abc/csv", locale: :none)
    end

    test "the path has no locale segment and ends with the export route" do
      path = Paths.export_logs("csv")
      refute path =~ ~r|/phoenix_kit/[a-z]{2}/|
      assert String.ends_with?(path, "/emails/export/logs/csv")
    end
  end

  describe "ExportController actions the routes dispatch to" do
    test "all four export actions exist (a missing one was a 500 per request)" do
      Code.ensure_loaded!(ExportController)
      assert function_exported?(ExportController, :export_logs, 2)
      assert function_exported?(ExportController, :export_metrics, 2)
      assert function_exported?(ExportController, :export_blocklist, 2)
      assert function_exported?(ExportController, :export_email_details, 2)
    end
  end

  describe "TemplateExport.files_for/2 name validation" do
    test "refuses a name that would escape the export directory" do
      assert_raise ArgumentError, ~r/unsafe name/, fn ->
        TemplateExport.files_for(%Template{name: "../evil"})
      end

      assert_raise ArgumentError, ~r/unsafe name/, fn ->
        TemplateExport.files_for(%Template{name: "a/b"})
      end

      assert_raise ArgumentError, ~r/non-string name/, fn ->
        TemplateExport.files_for(%Template{name: nil})
      end
    end

    test "accepts a safe name" do
      # A well-formed template with only a name produces no files (empty part
      # maps) but must not raise.
      assert TemplateExport.files_for(%Template{name: "welcome_email"}) == []
    end
  end
end
