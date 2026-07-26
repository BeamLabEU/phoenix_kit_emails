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

  ## Oban queue + cron configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        queues: [
          event_tracker_reconcile: 1,
          # ... your other queues
        ],
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"*/2 * * * *", PhoenixKit.Modules.Emails.EventTrackerReconcileWorker}
           ]}
        ]
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
