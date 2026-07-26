defmodule PhoenixKit.Modules.Emails.EventTrackerReconciler do
  @moduledoc """
  Stateless reconcile — the single code path that starts/stops a
  tracker's self-scheduling Oban chain, enforcing
  `EventTracker.should_run?/1`. See spec §4.2/§4.3.

  **Not a GenServer** (decision §9.1): the correctness backbone is the
  periodic reconcile Cron (`EventTrackerReconcileWorker`), not a
  long-lived orchestrator process. `reconcile/0`/`reconcile_tracker/1`
  are plain functions, safe to call from anywhere (boot, a settings
  toggle, the Cron tick, a future admin panel) — idempotent and
  cluster-safe:

  - "ensure exactly one chain" = an Oban `unique` insert — a genuinely
    dead chain gets a fresh immediate job (`schedule_in: 0`); a chain
    that's already alive (`:available`/`:scheduled`/`:executing`) hits
    the unique conflict and is left completely untouched, its own
    `scheduled_at` unchanged (no `replace:` — see `ensure_chain/1`'s own
    comment for why touching it would silently override the operator's
    own polling interval). Enforced at the DATABASE by Oban's own
    uniqueness, so two nodes reconciling simultaneously cannot create
    two chains (spec §8a).
  - "ensure none" = `Oban.cancel_all_jobs/1` scoped to `available`/
    `scheduled` only (never `executing` — a running cycle is never
    interrupted; it dies on its own next time it checks `should_run?/0`
    and doesn't self-reschedule, same mechanism `SQSPollingJob`/
    `BrevoPollingJob` already rely on for the disable path — see #21).

  A duplicate/racing insert at worst costs one extra no-op cycle
  (`should_run?/0`'s per-cycle gate inside the job itself is the real
  safety net) — never two live chains.
  """

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.EventTrackerRegistry

  @doc """
  Reconcile every registered tracker. Returns a list of
  `{tracker, result}` pairs, `result` being whatever
  `reconcile_tracker/1` returns for that tracker — never raises on a
  single tracker's failure (one broken tracker must not stop the rest
  from reconciling).
  """
  @spec reconcile() :: [{module(), term()}]
  def reconcile do
    Enum.map(EventTrackerRegistry.trackers(), fn tracker ->
      {tracker, reconcile_tracker(tracker)}
    end)
  end

  @doc """
  Reconcile a single tracker against `EventTracker.should_run?/1`.

  - `should_run? == true` → `{:ok, %Oban.Job{}}` (the chain's current job
    — the existing one, untouched, if the chain is already alive; a
    freshly inserted one, running immediately, if it wasn't).
  - `should_run? == false` → `{:ok, :not_running}` (any queued job for
    this tracker's worker was cancelled; a still-`executing` one is left
    to finish and die on its own).
  - `{:error, reason}` on an insert/cancel failure — logged, never
    raised, so a single tracker's transient DB hiccup during a Cron tick
    doesn't take down the rest.
  """
  @spec reconcile_tracker(module()) :: {:ok, Oban.Job.t() | :not_running} | {:error, term()}
  def reconcile_tracker(tracker) when is_atom(tracker) do
    if EventTracker.should_run?(tracker) do
      ensure_chain(tracker)
    else
      cancel_chain(tracker)
    end
  rescue
    error ->
      Logger.error(
        "EventTrackerReconciler: reconcile failed for #{inspect(tracker)}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  # unique: mirrors the managers' own "immediate job" shape (#21), PLUS
  # :executing — unlike the managers' insert (a per-call override on a
  # worker-level unique that itself excludes :executing to avoid a
  # self-reschedule from inside perform/1 conflicting with its own row),
  # reconcile is never called FROM inside a running cycle, so there is no
  # self-conflict to avoid here. Including :executing closes a real gap:
  # without it, calling ensure_chain/1 while a cycle is already executing
  # would insert a genuinely separate :available row, giving that tracker
  # two live jobs (one running, one about to start) — briefly violating
  # "never two live chains" for any concurrency > 1 (not forced by this
  # code, but not something the invariant should depend on either).
  #
  # Deliberately NO `replace:` (Kimi review, task #56 P2 follow-up): the
  # managers' own inserts use `replace: [scheduled: [:scheduled_at], ...]`
  # because THEY exist to force a chain to run right now (enable_polling/0,
  # poll_now/0). Reconcile's job is different — it should only ever
  # RESURRECT a dead chain, never touch a live one's own schedule. A
  # healthy chain's `:scheduled` row sits `interval_ms()` in the future;
  # with `replace:` here, every reconcile Cron tick (every ~2 min) would
  # find that row as a conflict and stomp its `scheduled_at` back to now —
  # silently clamping any operator-configured interval longer than the
  # Cron period down to the Cron period itself (e.g. a 10-minute Brevo
  # interval degrading to an effective ~2-minute one, 5x the API calls the
  # sender-aware gate's whole quota rationale assumes). Without `replace:`,
  # a live chain's conflict is a pure no-op — its own `scheduled_at` is
  # left exactly as the job itself set it. A dead chain has no conflicting
  # row at all, so this still inserts a fresh `schedule_in: 0` job and
  # resurrects it immediately — the one case reconcile actually needs to
  # act on.
  #
  # (:retryable is not in this states list, same as the managers' own
  # unique config — both SQSPollingJob/BrevoPollingJob perform/1 always
  # return :ok, so a job of either never actually reaches :retryable in
  # practice; not a gap that's expected to matter, just noted rather than
  # silently assumed.)
  defp ensure_chain(tracker) do
    worker = tracker.worker()

    result =
      %{}
      |> worker.new(
        schedule_in: 0,
        unique: [period: :infinity, states: [:available, :scheduled, :executing]]
      )
      |> Oban.insert()

    case result do
      {:ok, job} ->
        {:ok, job}

      {:error, reason} ->
        Logger.error(
          "EventTrackerReconciler: failed to ensure a chain for #{inspect(tracker)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp cancel_chain(tracker) do
    worker_name = inspect(tracker.worker())

    query =
      Oban.Job
      |> where([j], j.worker == ^worker_name)
      |> where([j], j.state in ["available", "scheduled"])

    # Oban.cancel_all_jobs/1 always returns {:ok, count} — no error tuple
    # to match against.
    {:ok, _count} = Oban.cancel_all_jobs(query)
    {:ok, :not_running}
  end
end
