defmodule PhoenixKit.Modules.Emails.Web.ExportController do
  @moduledoc """
  Controller for exporting email tracking data to CSV format.

  Provides server-side CSV export functionality for email logs, metrics,
  and blocklist data. Supports filtered exports based on query parameters.

  ## Features

  - **Email Logs Export**: Export filtered email logs to CSV
  - **Metrics Export**: Export email analytics and performance data
  - **Blocklist Export**: Export blocked email addresses
  - **Single Email Export**: Export individual email details
  - **Filter Support**: Respects all filtering parameters from LiveViews
  - **Large Dataset Streaming**: Efficient handling of large exports

  ## Security

  Access is restricted to users with admin or owner roles in PhoenixKit.
  All exports require proper authentication and authorization.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes

  # The route already gates on the admin role (`:phoenix_kit_admin_only`); this
  # plug adds the per-module gate the admin LiveViews get from core's
  # live_session hook, so a role that lacks the "emails" permission (or a host
  # with the module disabled) cannot pull the export even though it is admin.
  plug(:require_emails_module)

  @export_limit 1_000_000

  defp require_emails_module(conn, _opts) do
    scope = conn.assigns[:phoenix_kit_current_scope]
    enabled = Permissions.enabled_module_keys()

    if not is_nil(scope) and Scope.has_module_access?(scope, "emails") and
         MapSet.member?(enabled, "emails") do
      conn
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: Routes.path("/admin"))
      |> halt()
    end
  end

  ## --- Email Logs Export ---

  @doc """
  Export email logs to CSV based on filter parameters.

  ## Parameters

  - `search` - Search query for recipient, subject, or campaign
  - `status` - Filter by email status (sent, delivered, bounced, etc.)
  - `message_tag` - Filter by message type (authentication, marketing, etc.)
  - `campaign_id` - Filter by campaign ID
  - `from_date` - Start date filter (YYYY-MM-DD)
  - `to_date` - End date filter (YYYY-MM-DD)

  ## Response

  Returns CSV file with appropriate headers for browser download.
  """
  def export_logs(conn, params) do
    if Emails.enabled?() do
      format = params["format"] || "csv"
      filters = build_export_filters(params) |> Map.put(:limit, @export_limit)

      # Lift the list's default 50-row pagination cap: an export that silently
      # truncates to the first page is worse than no export.
      logs = Emails.list_logs(filters)

      send_export(conn, format, "email_logs_#{Date.utc_today()}", generate_logs_csv(logs), logs)
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: Routes.path("/admin"))
    end
  end

  @doc """
  Export email metrics data to CSV or JSON.

  ## Parameters

  - `period` - Time period (last_7_days, last_30_days, last_90_days, etc.)
  - `format` - `csv` or `json` (route param)

  ## Response

  Returns a file with email metrics and analytics data. The CSV carries the
  summary scalars as `Metric,Value` rows followed by the daily series; the
  JSON is the raw `Emails.get_engagement_metrics/1` map.
  """
  def export_metrics(conn, params) do
    if Emails.enabled?() do
      format = params["format"] || "csv"
      # Get metrics based on parameters
      period = validate_period(params["period"])

      # Get metrics data
      metrics = Emails.get_engagement_metrics(period)

      send_export(
        conn,
        format,
        "email_metrics_#{period}_#{Date.utc_today()}",
        generate_metrics_csv(metrics),
        metrics
      )
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: Routes.path("/admin"))
    end
  end

  @doc """
  Export email blocklist to CSV.

  ## Parameters

  - `reason` - Filter by block reason (rate_limit, manual, bounce, etc.)

  ## Response

  Returns CSV file with blocked email addresses and metadata.
  """
  def export_blocklist(conn, params) do
    if Emails.enabled?() do
      format = params["format"] || "csv"

      opts = %{include_expired: true}

      opts =
        if is_binary(params["reason"]) and params["reason"] != "",
          do: Map.put(opts, :reason, params["reason"]),
          else: opts

      blocked = RateLimiter.list_blocklist(opts)

      send_export(
        conn,
        format,
        "email_blocklist_#{Date.utc_today()}",
        generate_blocklist_csv(blocked),
        blocked
      )
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: Routes.path("/admin"))
    end
  end

  @doc """
  Export single email details to CSV.

  ## Parameters

  - `id` - Email log ID

  ## Response

  Returns CSV file with detailed email information and events.
  """
  def export_email_details(conn, %{"id" => email_uuid} = params) do
    if Emails.enabled?() do
      format = params["format"] || "csv"

      try do
        log = Emails.get_log!(email_uuid)
        # Get events for this email - use the log's uuid for Event query
        events = Emails.list_events_for_log(log.uuid)

        send_export(
          conn,
          format,
          "email_#{email_uuid}_details_#{Date.utc_today()}",
          generate_email_details_csv(log, events),
          %{email: log, events: events}
        )
      rescue
        Ecto.NoResultsError ->
          conn
          |> put_flash(:error, "Email not found")
          |> redirect(to: Routes.path("/admin/emails"))

        ArgumentError ->
          conn
          |> put_flash(:error, "Invalid email ID")
          |> redirect(to: Routes.path("/admin/emails"))
      end
    else
      conn
      |> put_flash(:error, "Email management is not enabled")
      |> redirect(to: Routes.path("/admin"))
    end
  end

  # Send an export in the requested format. `csv_content` is always built (it
  # is cheap and defines the canonical columns); `json_value` is encoded for
  # "json". Anything else is a 400, not a silent CSV.
  defp send_export(conn, format, filename_base, csv_content, json_value) do
    case format do
      "csv" ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename_base}.csv\"")
        |> send_resp(200, csv_content)

      "json" ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{filename_base}.json\""
        )
        |> send_resp(200, JSON.encode!(json_value))

      other ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          400,
          "Unsupported export format: #{inspect(other)}. Use \"csv\" or \"json\"."
        )
    end
  end

  # Generate CSV content for the blocklist
  defp generate_blocklist_csv(blocked) do
    headers = ["Email", "Reason", "Expires At", "Blocked At", "User UUID"]
    rows = Enum.map(blocked, &blocklist_to_csv_row/1)
    format_csv_output(headers, rows)
  end

  defp blocklist_to_csv_row(entry) do
    [
      entry.email || "",
      entry.reason || "",
      format_datetime_for_csv(entry.expires_at),
      format_datetime_for_csv(entry.inserted_at),
      entry.user_uuid || ""
    ]
  end

  ## --- Private Helper Functions ---

  # Build query filters from request parameters for email logs
  defp build_export_filters(params) do
    %{}
    |> add_string_filter(params, "search", :search, &String.trim/1)
    |> add_string_filter(params, "status", :status)
    |> add_string_filter(params, "message_tag", :message_tag)
    |> add_string_filter(params, "campaign_id", :campaign_id)
    |> add_date_filter(params, "from_date", :from_date, ~T[00:00:00])
    |> add_date_filter(params, "to_date", :to_date, ~T[23:59:59])
  end

  # Helper to add string filter
  defp add_string_filter(
         filters,
         params,
         param_key,
         filter_key,
         transform_fn \\ &Function.identity/1
       ) do
    case params[param_key] do
      value when is_binary(value) and value != "" ->
        Map.put(filters, filter_key, transform_fn.(value))

      _ ->
        filters
    end
  end

  # Helper to add date filter
  defp add_date_filter(filters, params, param_key, filter_key, time) do
    case params[param_key] do
      date_str when is_binary(date_str) and date_str != "" ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> Map.put(filters, filter_key, DateTime.new!(date, time))
          _ -> filters
        end

      _ ->
        filters
    end
  end

  # Generate CSV content for email logs
  defp generate_logs_csv(logs) do
    headers = get_logs_csv_headers()
    rows = Enum.map(logs, &log_to_csv_row/1)
    format_csv_output(headers, rows)
  end

  # Get CSV headers for email logs
  defp get_logs_csv_headers do
    [
      "ID",
      "Message ID",
      "To",
      "From",
      "Subject",
      "Status",
      "Message Type",
      "Provider",
      "Sent At",
      "Delivered At",
      "Campaign",
      "Template",
      "Size (bytes)",
      "Retry Count",
      "Error Message"
    ]
  end

  # Convert email log to CSV row
  defp log_to_csv_row(log) do
    basic_fields = get_log_basic_fields(log)
    datetime_fields = get_log_datetime_fields(log)
    metadata_fields = get_log_metadata_fields(log)

    basic_fields ++ datetime_fields ++ metadata_fields
  end

  # Get basic log fields
  defp get_log_basic_fields(log) do
    [
      log.uuid,
      log.message_id || "",
      log.to || "",
      log.from || "",
      log.subject || "",
      log.status || "",
      get_message_tag(log.message_tags) || "",
      log.provider || ""
    ]
  end

  # Get datetime fields
  defp get_log_datetime_fields(log) do
    [
      format_datetime_for_csv(log.sent_at),
      format_datetime_for_csv(log.delivered_at)
    ]
  end

  # Get metadata fields
  defp get_log_metadata_fields(log) do
    [
      log.campaign_id || "",
      log.template_name || "",
      log.size_bytes || "",
      log.retry_count || 0,
      log.error_message || ""
    ]
  end

  # Generate CSV content for metrics. `Emails.get_engagement_metrics/1` returns
  # a map of scalar summary stats plus a `daily_stats` list of per-day maps —
  # the old row mapper assumed every value was a stats map and crashed on the
  # scalars (`Access.get` on a float), 500ing every metrics CSV export. Emit
  # the scalars as Metric,Value rows, then the daily series as its own table.
  defp generate_metrics_csv(metrics) when is_map(metrics) do
    summary_rows =
      metrics
      |> Enum.reject(fn {_key, value} -> is_list(value) or is_map(value) end)
      |> Enum.map(fn {key, value} -> [Atom.to_string(key), to_string(value)] end)
      |> Enum.sort()

    daily_rows =
      case Map.get(metrics, :daily_stats) do
        list when is_list(list) -> Enum.map(list, &daily_stat_to_csv_row/1)
        _ -> []
      end

    summary = format_csv_output(["Metric", "Value"], summary_rows)

    if daily_rows == [] do
      summary
    else
      daily =
        format_csv_output(["Date", "Total Sent", "Delivered", "Opened", "Clicked"], daily_rows)

      summary <> "\n" <> daily
    end
  end

  defp daily_stat_to_csv_row(stat) when is_map(stat) do
    [
      case Map.get(stat, :date) do
        %Date{} = date -> Date.to_iso8601(date)
        other -> to_string(other || "")
      end,
      Map.get(stat, :total_sent, 0),
      Map.get(stat, :delivered, 0),
      Map.get(stat, :opened, 0),
      Map.get(stat, :clicked, 0)
    ]
  end

  # Generate CSV content for email details
  defp generate_email_details_csv(log, events) do
    email_section = build_email_details_section(log)
    events_section = build_events_section(events)
    combine_csv_sections(email_section, events_section)
  end

  # Build email details section
  defp build_email_details_section(log) do
    headers = ["Field", "Value"]
    rows = get_email_detail_rows(log)
    [headers | rows]
  end

  # Get email detail rows
  defp get_email_detail_rows(log) do
    [
      ["UUID", log.uuid],
      ["Message ID", log.message_id || ""],
      ["To", log.to || ""],
      ["From", log.from || ""],
      ["Subject", log.subject || ""],
      ["Status", log.status || ""],
      ["Provider", log.provider || ""],
      ["Sent At", format_datetime_for_csv(log.sent_at)],
      ["Delivered At", format_datetime_for_csv(log.delivered_at)],
      ["Campaign", log.campaign_id || ""],
      ["Template", log.template_name || ""],
      ["Size (bytes)", log.size_bytes || ""],
      ["Retry Count", log.retry_count || 0]
    ]
  end

  # Build events section
  defp build_events_section([]), do: []

  defp build_events_section(events) do
    headers = ["Event Type", "Occurred At", "Details"]
    rows = Enum.map(events, &event_to_csv_row/1)
    [[], ["EVENTS"], headers | rows]
  end

  # Convert event to CSV row
  defp event_to_csv_row(event) do
    [
      event.event_type || "",
      format_datetime_for_csv(event.occurred_at),
      event.event_data || ""
    ]
  end

  # Combine CSV sections
  defp combine_csv_sections(email_section, events_section) do
    (email_section ++ events_section)
    |> Enum.map_join("\n", &format_csv_row/1)
  end

  # Format CSV output from headers and rows
  defp format_csv_output(headers, rows) do
    [headers | rows]
    |> Enum.map_join("\n", &format_csv_row/1)
  end

  # Join a row into a CSV line, escaping every cell exactly once for both
  # formula injection and RFC 4180 quoting.
  defp format_csv_row(row) do
    Enum.map_join(row, ",", &escape_csv_field/1)
  end

  # Format datetime for CSV export
  defp format_datetime_for_csv(nil), do: ""

  defp format_datetime_for_csv(datetime) do
    DateTime.to_iso8601(datetime)
  end

  # Escape CSV field value, including formula injection protection.
  # Cells starting with =, +, -, @, tab, or CR are prefixed with a single quote
  # to prevent formula execution when opened in spreadsheet applications.
  defp escape_csv_field(nil), do: ""

  defp escape_csv_field(value) when is_binary(value) do
    value = sanitize_csv_formula(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_csv_field(value), do: value |> to_string() |> escape_csv_field()

  defp sanitize_csv_formula(<<first, _::binary>> = value)
       when first in [?=, ?+, ?-, ?@, ?\t, ?\r] do
    "'" <> value
  end

  defp sanitize_csv_formula(value), do: value

  # Extract message tag from message_tags map
  defp get_message_tag(message_tags) when is_map(message_tags) do
    Map.get(message_tags, "email_type")
  end

  defp get_message_tag(_), do: nil

  defp validate_period(nil), do: :last_30_days

  defp validate_period(str)
       when str in ~w(last_24_hours last_7_days last_30_days last_90_days all_time),
       do: String.to_existing_atom(str)

  defp validate_period(_), do: :last_30_days
end
