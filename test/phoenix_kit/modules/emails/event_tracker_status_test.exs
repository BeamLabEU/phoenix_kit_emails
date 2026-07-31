defmodule PhoenixKit.Modules.Emails.EventTrackerStatusTest do
  @moduledoc """
  `EventTracker.state/1`, `pending_jobs_count/1`, `last_polled_at/1` —
  the generic, `worker/0`-derived helpers the admin panel (task #56 P2)
  reads for every registered tracker. Uses `FakeEventTracker` so the
  4-state matrix can be asserted without real SES/Brevo fixtures.

  Also covers `integration_count/1`, `accounts/1`, `toggle_account_
  polling/2` — the guarded wrappers around the three optional
  `EventTracker` callbacks (P2 dual-review fix, item 1): `FakeEventTracker`
  defines none of the three, so it's the fixture that proves a tracker
  skipping them gets a safe default/no-op rather than crashing whatever
  called them.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.FakeEventTracker
  alias PhoenixKit.Modules.Emails.FakeEventTrackerWorker
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_emails, :fake_tracker_eligible)
      Application.delete_env(:phoenix_kit_emails, :fake_tracker_enabled)
    end)

    :ok
  end

  defp set_should_run(eligible, enabled) do
    Application.put_env(:phoenix_kit_emails, :fake_tracker_eligible, eligible)
    Application.put_env(:phoenix_kit_emails, :fake_tracker_enabled, enabled)
  end

  describe "pending_jobs_count/1" do
    test "0 when the tracker's worker has no jobs at all" do
      assert EventTracker.pending_jobs_count(FakeEventTracker) == 0
    end

    test "counts available, scheduled, and executing, not completed/cancelled" do
      {:ok, _} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()
      {:ok, _} = %{} |> FakeEventTrackerWorker.new(schedule_in: 60) |> Oban.insert()
      {:ok, executing} = %{} |> FakeEventTrackerWorker.new(schedule_in: 120) |> Oban.insert()
      {:ok, completed} = %{} |> FakeEventTrackerWorker.new(schedule_in: 180) |> Oban.insert()
      {:ok, cancelled} = %{} |> FakeEventTrackerWorker.new(schedule_in: 240) |> Oban.insert()

      import Ecto.Query

      Repo.update_all(from(j in Oban.Job, where: j.id == ^executing.id),
        set: [state: "executing"]
      )

      Repo.update_all(from(j in Oban.Job, where: j.id == ^completed.id),
        set: [state: "completed"]
      )

      Repo.update_all(from(j in Oban.Job, where: j.id == ^cancelled.id),
        set: [state: "cancelled"]
      )

      assert EventTracker.pending_jobs_count(FakeEventTracker) == 3
    end
  end

  describe "last_polled_at/1" do
    test "nil when the tracker's worker has never completed a job" do
      assert EventTracker.last_polled_at(FakeEventTracker) == nil
    end

    test "the most recent completed job's completed_at" do
      import Ecto.Query

      {:ok, older} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()
      {:ok, newer} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()

      older_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      newer_at = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^older.id),
        set: [state: "completed", completed_at: older_at]
      )

      Repo.update_all(from(j in Oban.Job, where: j.id == ^newer.id),
        set: [state: "completed", completed_at: newer_at]
      )

      assert DateTime.compare(EventTracker.last_polled_at(FakeEventTracker), newer_at) == :eq
    end
  end

  describe "state/1" do
    test ":off when enabled? is false, regardless of eligible? or queued jobs" do
      set_should_run(true, false)
      {:ok, _} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()

      assert EventTracker.state(FakeEventTracker) == :off
    end

    test ":idle_no_integration when enabled? is true but eligible? is false" do
      set_should_run(false, true)
      assert EventTracker.state(FakeEventTracker) == :idle_no_integration
    end

    test ":active when should_run? is true and a job is queued" do
      set_should_run(true, true)
      {:ok, _} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()

      assert EventTracker.state(FakeEventTracker) == :active
    end

    test ":stalled when should_run? is true but zero jobs are queued" do
      set_should_run(true, true)
      assert EventTracker.state(FakeEventTracker) == :stalled
    end

    test ":active counts an :executing job, not just available/scheduled" do
      set_should_run(true, true)
      {:ok, job} = %{} |> FakeEventTrackerWorker.new() |> Oban.insert()

      import Ecto.Query
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      assert EventTracker.state(FakeEventTracker) == :active
    end
  end

  describe "integration_count/1, accounts/1, toggle_account_polling/2 — a tracker without the optional callbacks" do
    test "integration_count/1 falls back to eligible? cast to 1/0" do
      set_should_run(false, true)
      assert EventTracker.integration_count(FakeEventTracker) == 0

      set_should_run(true, true)
      assert EventTracker.integration_count(FakeEventTracker) == 1
    end

    test "accounts/1 falls back to nil (not applicable)" do
      assert EventTracker.accounts(FakeEventTracker) == nil
    end

    test "toggle_account_polling/2 is a safe no-op, not an UndefinedFunctionError" do
      assert {:ok, _} = EventTracker.toggle_account_polling(FakeEventTracker, "some-uuid")
    end
  end
end
