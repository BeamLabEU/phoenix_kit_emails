defmodule PhoenixKit.Modules.Emails.EventTrackerReconcileWorkerTest do
  @moduledoc """
  The reconcile Cron worker (spec §4.3's correctness backbone). Exercises
  `perform/1` directly against real registered trackers, since it's a
  thin call-through to `EventTrackerReconciler.reconcile/0`.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.EventTrackerReconcileWorker
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  test "perform/1 reconciles every registered tracker and returns :ok" do
    assert :ok = EventTrackerReconcileWorker.perform(%Oban.Job{})
  end

  test "perform/1 returns :ok even when every tracker is not-running (nothing configured)" do
    assert :ok = EventTrackerReconcileWorker.perform(%Oban.Job{})
  end
end
