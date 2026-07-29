defmodule PhoenixKit.Modules.Emails.SendJobTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Emails.SendJob

  # Only the parts of the worker that decide *without* sending: the malformed-args
  # guard and the last-attempt predicate that closes a stuck log row. Everything
  # past `deliver_email/2` needs a database and a relay.

  describe "perform/1 with args that carry no email" do
    test "cancels instead of retrying five times against the same bad args" do
      log =
        capture_log(fn ->
          assert SendJob.perform(%Oban.Job{args: %{}}) == {:cancel, :malformed_args}
          assert SendJob.perform(%Oban.Job{args: %{"opts" => %{}}}) == {:cancel, :malformed_args}
        end)

      assert log =~ "malformed job args"
    end
  end

  describe "job option defaults" do
    test "runs on the :emails queue the host has to declare, with bounded retries" do
      # Both are load-bearing elsewhere: Status counts jobs by this queue name,
      # and Queue.runnable?/0 refuses to enqueue unless the host declared it.
      changeset = SendJob.new(%{"email" => %{"to" => [["", "a@example.com"]]}})

      assert Ecto.Changeset.get_field(changeset, :queue) == "emails"
      assert Ecto.Changeset.get_field(changeset, :max_attempts) == 5
    end
  end
end
