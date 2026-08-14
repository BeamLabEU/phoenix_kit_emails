defmodule PhoenixKit.Modules.Emails.ArchiveWorkerTest do
  @moduledoc """
  The scheduled half of archival, and the hand-off between the two jobs that
  share a cutoff.

  The interesting assertion is the last one: with archival enabled, retention
  cleanup must not delete a row archival has not stamped. Before that guard the
  two jobs raced over the same `email_retention_days` boundary, and losing the
  race destroyed rows the operator believed were in cold storage — silently,
  since nothing afterwards can tell an archived row from a deleted one.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.{ArchiveWorker, Log}
  alias PhoenixKit.Utils.Date, as: UtilsDate

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp old_log(days_ago) do
    sent_at =
      UtilsDate.utc_now()
      |> DateTime.add(-days_ago * 86_400)
      |> DateTime.truncate(:second)

    {:ok, log} =
      Emails.create_log(%{
        message_id: "msg-#{System.unique_integer([:positive])}",
        to: "to@example.com",
        from: "from@example.com",
        subject: "s",
        provider: "aws_ses",
        status: "sent",
        sent_at: sent_at
      })

    log
  end

  describe "a tick with the feature off" do
    test "does nothing and does not fail" do
      {:ok, _} = Emails.set_s3_archival(false)

      assert :ok = ArchiveWorker.perform(%Oban.Job{})
    end
  end

  describe "a tick with the feature on but unconfigured" do
    test "reports the gap without burning a retry" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("")

      assert :ok = ArchiveWorker.perform(%Oban.Job{}),
             "a missing bucket is a configuration gap, not a transient error: " <>
               "retrying it inside the tick only spends attempts"
    end
  end

  describe "retention cleanup while archival is on" do
    test "refuses to delete a row archival has not shipped yet" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("some-bucket")
      {:ok, _} = Emails.set_retention_days(90)

      unshipped = old_log(120)

      {_deleted, nil} = Emails.cleanup_old_logs()

      assert Emails.get_log(unshipped.uuid),
             "cleanup deleted a row that was still owed an upload"
    end

    test "deletes it on a later pass, once archival has stamped it" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("some-bucket")
      {:ok, _} = Emails.set_retention_days(90)

      shipped = old_log(120)
      {1, nil} = Log.mark_archived([shipped.uuid], "logs/batch.json")

      {_deleted, nil} = Emails.cleanup_old_logs()

      refute Emails.get_log(shipped.uuid)
    end

    test "with archival off, cleanup is unchanged and deletes regardless" do
      {:ok, _} = Emails.set_s3_archival(false)
      {:ok, _} = Emails.set_retention_days(90)

      log = old_log(120)

      {_deleted, nil} = Emails.cleanup_old_logs()

      refute Emails.get_log(log.uuid),
             "the guard leaked into installs that never asked for archival"
    end
  end

  describe "the hold-back is not a foot-gun" do
    test "archival enabled with no bucket does not stop retention cleanup" do
      # Flipping the toggle and forgetting the bucket used to disable retention
      # permanently: nothing can stamp a row, so nothing is ever deletable, and
      # the table grows while the page still shows a retention period.
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("")
      {:ok, _} = Emails.set_retention_days(90)

      log = old_log(120)

      {_deleted, nil} = Emails.cleanup_old_logs()

      refute Emails.get_log(log.uuid),
             "a half-configured feature disabled a working one"
    end

    test "with a bucket set, the hold-back applies again" do
      {:ok, _} = Emails.set_s3_archival(true)
      {:ok, _} = Emails.set_s3_bucket("real-bucket")
      {:ok, _} = Emails.set_retention_days(90)

      log = old_log(120)

      {_deleted, nil} = Emails.cleanup_old_logs()

      assert Emails.get_log(log.uuid)
    end

    test "the count behind the hold-back is reported, not guessed" do
      {:ok, _} = Emails.set_retention_days(90)

      old_log(120)
      old_log(120)
      old_log(10)

      assert Log.count_unarchived_past_retention(90) == 2
    end
  end
end
