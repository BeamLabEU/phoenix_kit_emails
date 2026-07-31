defmodule PhoenixKit.Modules.Emails.FakeEventTrackerWorker do
  @moduledoc false
  use Oban.Worker, queue: :fake_tracker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule PhoenixKit.Modules.Emails.FakeEventTracker do
  @moduledoc """
  Test-only `EventTracker` with controllable `eligible?/0`/`enabled?/0`,
  via `:phoenix_kit_emails, :fake_tracker_eligible` / `:fake_tracker_enabled`
  application config — set/reset per test (see `on_exit`). Used by
  `EventTrackerReconcilerTest` to exercise the reconcile invariant without
  depending on real Settings/Integrations fixtures.
  """

  @behaviour PhoenixKit.Modules.Emails.EventTracker

  alias PhoenixKit.Modules.Emails.FakeEventTrackerWorker

  @impl true
  def provider_kind, do: "fake"

  @impl true
  def label, do: "Fake Tracker"

  @impl true
  def eligible?, do: Application.get_env(:phoenix_kit_emails, :fake_tracker_eligible, false)

  @impl true
  def enabled?, do: Application.get_env(:phoenix_kit_emails, :fake_tracker_enabled, false)

  @impl true
  def poll_cycle(_context), do: :ok

  @impl true
  def interval_ms, do: 60_000

  @impl true
  def min_interval_ms, do: 1_000

  @impl true
  def worker, do: FakeEventTrackerWorker
end
