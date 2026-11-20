defmodule PhoenixKit.Modules.Emails.Web.Routes do
  @moduledoc """
  Public route definitions for Emails module.
  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  """

  def generate(url_prefix) do
    webhook_controller = PhoenixKit.Modules.Emails.Web.WebhookController
    export_controller = PhoenixKit.Modules.Emails.Web.ExportController

    quote do
      # AWS SNS delivers webhook notifications as a cold, session-less POST
      # — it never carries a CSRF token or session cookie. Routing it
      # through the host's :browser pipeline (protect_from_forgery) would
      # 403 every notification. Deliberately minimal/self-contained so it
      # doesn't assume anything about what else the host app's :browser
      # pipeline includes (mirrors the newsletters one-click unsubscribe
      # pipeline).
      pipeline :phoenix_kit_emails_webhook do
        plug(:accepts, ["html"])
      end

      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_emails_webhook])
        post("/webhooks/ses", unquote(webhook_controller), :handle)
      end

      # Export requires admin authentication. One route per action — the
      # controller has no catch-all `export/2`, so a single `:export` action
      # here 500s on every request.
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_admin_only])
        get("/emails/export/logs/:format", unquote(export_controller), :export_logs)
        get("/emails/export/metrics/:format", unquote(export_controller), :export_metrics)
        get("/emails/export/blocklist/:format", unquote(export_controller), :export_blocklist)
        get("/emails/export/email/:id/:format", unquote(export_controller), :export_email_details)
      end
    end
  end
end
