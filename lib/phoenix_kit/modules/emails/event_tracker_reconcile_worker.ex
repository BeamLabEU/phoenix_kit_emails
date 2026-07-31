defmodule PhoenixKit.Modules.Emails.EventTrackerReconcileWorker do
  @moduledoc """
  The correctness backbone of the tracker lifecycle (spec §4.3): a
  low-frequency Oban `Cron` entry that calls
  `EventTrackerReconciler.reconcile/0` for every registered tracker.

  The boot and settings-toggle reconcile calls are latency polish — they
  make an eligibility/toggle change *feel* instant. This Cron tick is
  what makes it *correct* no matter what: it is the only trigger that can
  **resurrect** a chain that died or was never started (e.g. spec §1.1 —
  a `SendProfile` change emits no PubSub today, so it's the dominant way
  a newly-eligible Brevo tracker actually gets picked up without an
  operator manually re-toggling).

  Runs in its own `:event_tracker_reconcile` queue (not `:sqs_polling`/
  `:brevo_polling`) — it must never be blocked behind either provider's
  own chain.

  ## Multi-node

  `Oban.Plugins.Cron` is not node-scoped by default — on a multi-node
  cluster, every node's Oban instance fires this Cron entry on its own
  schedule, so a single tick can produce N concurrent `perform/1` calls
  (one per node), each running a full `reconcile/0`. This is safe and
  cheap, not a bug to work around: `reconcile/0` is idempotent and its
  "ensure exactly one chain" step is enforced at the database by Oban's
  own `unique` (spec §8a) — N simultaneous reconciles collapse to the
  same single chain regardless. If a host genuinely needs only one node
  running this Cron entry (e.g. to avoid N redundant reconcile queries
  on a very large tracker registry), that requires a host-side node
  filter (e.g. `Oban.Plugins.Cron`'s own node-targeting options, or an
  application-level leader check) — this worker itself does nothing to
  enforce single-node execution.

  ## Oban queue + cron configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        queues: [
          event_tracker_reconcile: 1,
          # ... your other queues
        ],
        plugins: [
          Oban.Plugins.Pruner,
          Oban.Plugins.Lifeline,
          {Oban.Plugins.Cron,
           crontab: [
             {"*/2 * * * *", PhoenixKit.Modules.Emails.EventTrackerReconcileWorker}
           ]}
        ]

  ## Why `Oban.Plugins.Lifeline` belongs in that list

  Reconcile can only resurrect a chain it can see is dead.
  `EventTrackerReconciler.ensure_chain/1`'s `unique` covers `:executing`
  (deliberately — see its own comment), so a job orphaned in `:executing`
  by a node that died mid-cycle is a permanent conflict: reconcile never
  inserts a successor, and `EventTracker.state/1` — which counts
  `:executing` too — keeps reporting `:active` / "Running normally" for a
  tracker that has in fact stopped polling. Nothing in this package can
  detect that from the outside; `Oban.Plugins.Lifeline` is what moves
  orphaned rows back to `:available`, at which point the next tick here
  behaves normally again. `Oban.Plugins.Pruner` is listed for the same
  "don't paste a `plugins:` list that silently drops your existing ones"
  reason, plus `EventTracker.last_polled_at/1`'s own Pruner caveat.
  """

  use Oban.Worker, queue: :event_tracker_reconcile, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Emails.EventTrackerReconciler

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = EventTrackerReconciler.reconcile()

    errors = for {tracker, {:error, reason}} <- results, do: {tracker, reason}

    if errors == [] do
      :ok
    else
      Logger.error("EventTrackerReconcileWorker: reconcile errors", %{errors: inspect(errors)})
      :ok
    end
  end
end
