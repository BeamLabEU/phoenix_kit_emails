defmodule PhoenixKit.Modules.Emails.Paths do
  @moduledoc "Centralized path helpers for Emails module."
  alias PhoenixKit.Utils.Routes

  @base "/admin/emails"

  def emails_index, do: Routes.path(@base)
  def email_details(id), do: Routes.path("#{@base}/email/#{id}")
  def dashboard, do: Routes.path("#{@base}/dashboard")
  def queue, do: Routes.path("#{@base}/queue")
  def blocklist, do: Routes.path("#{@base}/blocklist")
  def settings, do: Routes.path("/admin/settings/email-sending")

  # Public export routes are mounted root-scoped by core (`Web.Routes.generate/1`
  # emits them under `scope url_prefix`, never under `/:locale`), so they must be
  # built with `locale: :none` — `Routes.path/1` would otherwise prepend a locale
  # segment that no route matches and the link would 404.
  def export_logs(format), do: Routes.path("/emails/export/logs/#{format}", locale: :none)

  def export_metrics(format), do: Routes.path("/emails/export/metrics/#{format}", locale: :none)

  def export_blocklist(format),
    do: Routes.path("/emails/export/blocklist/#{format}", locale: :none)

  def export_email(id, format),
    do: Routes.path("/emails/export/email/#{id}/#{format}", locale: :none)
end
