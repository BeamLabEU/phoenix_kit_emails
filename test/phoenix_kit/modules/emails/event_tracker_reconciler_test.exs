defmodule PhoenixKit.Modules.Emails.EventTrackerReconcilerTest do
  @moduledoc """
  Reconcile invariant (spec §8): "for a `should_run?` tracker, exactly
  one chain queued; otherwise none" — idempotent, and reacts correctly
  to eligible?/enabled? transitions. Uses `FakeEventTracker`
  (test/support) rather than the real SES/Brevo trackers so the
  invariant itself can be asserted without needing real
  Settings/Integrations fixtures — those are exercised separately in
  `EventTrackerReconcilerLifecycleTest`.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
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

  defp fake_tracker_jobs do
    worker_name = inspect(FakeEventTrackerWorker)

    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker_name and j.state in ["available", "scheduled"]
      )
    )
  end

  describe "reconcile_tracker/1 — the invariant" do
    test "should_run? true: exactly one job queued" do
      set_should_run(true, true)

      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert [_one] = fake_tracker_jobs()
    end

    test "should_run? false: zero jobs queued" do
      set_should_run(false, false)

      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []
    end

    test "eligible but not enabled: zero jobs" do
      set_should_run(true, false)

      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []
    end

    test "enabled but not eligible: zero jobs" do
      set_should_run(false, true)

      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []
    end
  end

  describe "reconcile_tracker/1 — idempotency" do
    test "calling it repeatedly while should_run? stays true never creates a second job" do
      set_should_run(true, true)

      assert {:ok, first} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert {:ok, second} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert {:ok, third} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)

      assert first.id == second.id
      assert second.id == third.id
      assert [_one] = fake_tracker_jobs()
    end

    test "calling it repeatedly while should_run? stays false is a no-op every time" do
      set_should_run(false, false)

      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []
    end
  end

  describe "reconcile_tracker/1 — never two live chains, even mid-cycle" do
    test "should_run? true while a chain is already :executing: no second row is inserted" do
      {:ok, executing_job} = %{} |> FakeEventTrackerWorker.new(schedule_in: 60) |> Oban.insert()

      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^executing_job.id),
        set: [state: "executing"]
      )

      set_should_run(true, true)
      assert {:ok, %Oban.Job{id: id}} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)

      # The conflict resolved to the executing row itself — no new
      # :available/:scheduled row alongside it.
      assert id == executing_job.id

      worker_name = inspect(FakeEventTrackerWorker)
      all_jobs = Repo.all(from(j in Oban.Job, where: j.worker == ^worker_name))

      assert [%Oban.Job{state: "executing"}] = all_jobs
    end
  end

  describe "reconcile_tracker/1 — transitions" do
    test "should_run? flips true -> false: the queued job is cancelled" do
      set_should_run(true, true)
      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert [_one] = fake_tracker_jobs()

      set_should_run(false, true)
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []
    end

    test "should_run? flips false -> true: a job is inserted" do
      set_should_run(false, false)
      assert {:ok, :not_running} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert fake_tracker_jobs() == []

      set_should_run(true, true)
      assert {:ok, %Oban.Job{}} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)
      assert [_one] = fake_tracker_jobs()
    end

    test "a stale future job gets moved to run now, not duplicated" do
      {:ok, existing} =
        %{} |> FakeEventTrackerWorker.new(schedule_in: 3_600) |> Oban.insert()

      far_future = existing.scheduled_at
      set_should_run(true, true)

      assert {:ok, moved} = EventTrackerReconciler.reconcile_tracker(FakeEventTracker)

      assert moved.id == existing.id
      assert DateTime.compare(moved.scheduled_at, far_future) == :lt
      assert [_one] = fake_tracker_jobs()
    end
  end

  describe "reconcile/0 — every registered tracker" do
    test "returns a {tracker, result} pair for each registered tracker" do
      results = EventTrackerReconciler.reconcile()
      trackers = Enum.map(results, &elem(&1, 0))

      assert PhoenixKit.Modules.Emails.SQSPollingManager in trackers
      assert PhoenixKit.Modules.Emails.BrevoPollingManager in trackers
    end
  end
end
