defmodule PhoenixKit.Modules.Emails.ArchiverTest do
  @moduledoc """
  S3 archival, up to the network boundary.

  The package has no HTTP stub, so nothing here calls `ExAws.request/2`. That
  is not a gap in coverage so much as a statement about where the bugs were:
  every one of them lived on this side of the wire. The archive that contained
  no events, the body labelled `application/gzip`, the request signed with no
  credentials, the blank bucket that read as a bucket, and the run that
  re-uploaded the same rows forever — all of them are decided before a single
  byte is sent, and all of them are asserted below.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.{Archiver, Log}
  alias PhoenixKit.Utils.Date, as: UtilsDate

  setup do
    {:ok, _} = Emails.enable_system()

    on_exit(fn ->
      Emails.invalidate_aws_credentials_cache()
    end)

    :ok
  end

  defp old_log(days_ago, attrs \\ %{}) do
    sent_at =
      UtilsDate.utc_now()
      |> DateTime.add(-days_ago * 86_400)
      |> DateTime.truncate(:second)

    {:ok, log} =
      Emails.create_log(
        Map.merge(
          %{
            message_id: "msg-#{System.unique_integer([:positive])}",
            to: "to@example.com",
            from: "from@example.com",
            subject: "archived subject",
            provider: "aws_ses",
            status: "sent",
            sent_at: sent_at
          },
          attrs
        )
      )

    log
  end

  describe "selecting rows to archive" do
    test "a row already stamped as archived is not a candidate again" do
      fresh = old_log(120)
      shipped = old_log(120)

      {1, nil} = Log.mark_archived([shipped.uuid], "email-logs/2026/batch-abc.json")

      uuids = Enum.map(Log.get_logs_for_archival(90), & &1.uuid)

      assert fresh.uuid in uuids

      refute shipped.uuid in uuids,
             "an archived row came back as a candidate: a run that keeps its rows " <>
               "would re-upload the same messages on every pass"
    end

    test "rows younger than the cutoff are left alone" do
      recent = old_log(10)
      old = old_log(120)

      uuids = Enum.map(Log.get_logs_for_archival(90), & &1.uuid)

      assert old.uuid in uuids
      refute recent.uuid in uuids
    end
  end

  describe "mark_archived/3" do
    test "stamps both columns and reports how many rows it touched" do
      log = old_log(120)
      at = UtilsDate.utc_now()

      assert {1, nil} = Log.mark_archived([log.uuid], "logs/batch-1.json", at)

      reloaded = Emails.get_log!(log.uuid)
      assert reloaded.s3_key == "logs/batch-1.json"
      assert DateTime.compare(reloaded.archived_at, at) == :eq
    end

    test "a second pass cannot overwrite the key of an object already written" do
      log = old_log(120)

      {1, nil} = Log.mark_archived([log.uuid], "logs/first.json")
      assert {0, nil} = Log.mark_archived([log.uuid], "logs/second.json")

      assert Emails.get_log!(log.uuid).s3_key == "logs/first.json"
    end

    test "an empty batch is not a query" do
      assert {0, nil} = Log.mark_archived([], "logs/none.json")
    end
  end

  describe "the archival gate" do
    test "refuses while the feature is off" do
      {:ok, _} = Emails.set_s3_archival(false)
      assert {:error, :s3_not_configured} = Archiver.archive_to_s3(90)
    end

    test "refuses when no bucket is set" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("")

      assert {:error, :no_bucket_configured} = Archiver.archive_to_s3(90)
    end

    test "a bucket of whitespace is no bucket" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("   ")

      assert {:error, :no_bucket_configured} = Archiver.archive_to_s3(90),
             "a blank setting passed the `if bucket do` guard and the upload " <>
               "was attempted against a bucket named \"\""
    end
  end

  describe "what actually goes into the object" do
    test "events are encoded beside their log, not inside it" do
      log = old_log(120)

      {:ok, _} =
        Emails.create_event(%{
          email_log_uuid: log.uuid,
          event_type: "delivery",
          occurred_at: UtilsDate.utc_now()
        })

      payload =
        [log]
        |> Archiver.prepare_archive_data(:json, true)
        |> JSON.decode!()

      assert payload["includes_events"] == true
      assert [record] = payload["records"]
      assert record["log"]["uuid"] == log.uuid

      assert [event] = record["events"],
             "the events were dropped: `Log` derives JSON.Encoder with " <>
               "`except: [..., :events]`, so anything put on that key vanishes"

      assert event["event_type"] == "delivery"
    end

    test "events are omitted, and said to be omitted, when not requested" do
      log = old_log(120)

      {:ok, _} =
        Emails.create_event(%{
          email_log_uuid: log.uuid,
          event_type: "delivery",
          occurred_at: UtilsDate.utc_now()
        })

      payload =
        [log]
        |> Archiver.prepare_archive_data(:json, false)
        |> JSON.decode!()

      assert payload["includes_events"] == false
      assert [%{"events" => []}] = payload["records"]
    end

    test "the log body survives the round trip" do
      # Bodies are only stored when the system is configured to keep them; the
      # point here is that whatever the row holds reaches the object.
      {:ok, _} = Emails.set_save_body(true)
      log = old_log(120, %{subject: "keep me", body_full: "the whole body"})

      payload =
        [log]
        |> Archiver.prepare_archive_data(:json, false)
        |> JSON.decode!()

      assert [%{"log" => encoded}] = payload["records"]
      assert encoded["subject"] == "keep me"
      assert encoded["body_full"] == "the whole body"
    end

    test "csv still carries one header and one row per log" do
      log = old_log(120)

      csv = Archiver.prepare_archive_data([log], :csv, false)

      assert [header, row] = String.split(String.trim(csv), "\n")
      assert header =~ "uuid,message_id"
      assert row =~ log.message_id
    end

    test "the content type describes the body, not a compression that never happened" do
      assert Archiver.content_type(:json) == "application/json"
      assert Archiver.content_type(:csv) == "text/csv"
    end
  end

  describe "credentials for the upload" do
    test "an unset connection leaves ExAws to its own resolution chain" do
      {:ok, _} = Emails.set_s3_integration("")

      assert Archiver.s3_request_config() == [],
             "an empty override is the deliberate answer: environment keys, " <>
               "instance profiles and task roles must keep working"
    end

    test "a chosen connection signs the request" do
      {:ok, %{uuid: uuid}} =
        Integrations.add_connection("aws_ses", "archive #{System.unique_integer([:positive])}")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIAARCHIVE",
          "secret_key" => "archive-secret",
          "aws_region" => "eu-north-1"
        })

      Emails.invalidate_aws_credentials_cache()
      {:ok, _} = Emails.set_s3_integration(uuid)

      config = Archiver.s3_request_config()

      assert config[:access_key_id] == "AKIAARCHIVE"
      assert config[:secret_access_key] == "archive-secret"
      assert config[:region] == "eu-north-1"
    end

    test "a connection that stores no credentials falls back rather than signing with nils" do
      {:ok, %{uuid: uuid}} =
        Integrations.add_connection("aws_ses", "empty #{System.unique_integer([:positive])}")

      Emails.invalidate_aws_credentials_cache()
      {:ok, _} = Emails.set_s3_integration(uuid)

      assert Archiver.s3_request_config() == []
    end
  end

  describe "storage statistics" do
    test "archived rows are counted instead of being reported as zero" do
      log = old_log(120)
      {1, nil} = Log.mark_archived([log.uuid], "logs/batch.json")

      stats = Archiver.get_storage_stats()

      assert stats.archived_logs >= 1,
             "archived rows used to be hardcoded to 0, so the settings page " <>
               "reported nothing had ever been shipped"

      # A single 2KB row rounds to 0.0 MB — the assertion is that the number is
      # now derived at all, not that one row is visible in megabytes.
      assert is_float(stats.s3_archived_size_mb)
    end
  end

  describe "the object key" do
    test "is a browsable date hierarchy with no characters that need escaping" do
      key = Archiver.object_path(~U[2026-08-14 09:07:03Z])

      assert key == "2026/08/14/090703"

      refute key =~ ":",
             "an ISO-8601 timestamp in the key puts colons in every object name — " <>
               "legal in S3, but they need escaping in URLs and quoting in shells"
    end
  end
end
