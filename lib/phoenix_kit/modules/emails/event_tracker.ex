defmodule PhoenixKit.Modules.Emails.EventTracker do
  @moduledoc """
  Behaviour every provider delivery-event tracker implements (SES, Brevo,
  future Mailgun/…). See
  `dev_docs/specs/2026-07-26-email-event-tracking-universalization-spec.md`
  §4.1 for the full design rationale.

  The lifecycle invariant every registered tracker must satisfy:

  > iff `should_run?/1` (== `eligible?/1 and enabled?/1`), exactly one
  > self-scheduling Oban chain is queued for `worker/1`; otherwise none.

  `EventTrackerReconciler` is what actually enforces this — a tracker
  only needs to answer the callbacks below honestly.

  ## `eligible?/1` vs `enabled?/1` — not the same gate

  `eligible?/1` folds every *feature/source* gate: "does a working event
  source exist for this provider at all". `enabled?/1` is *only* the
  operator's polling on/off switch. Conflating them was the SES poller's
  original bug (`SQSPollingJob.should_poll?/0` gates on three things —
  `Emails.enabled?()`, `email_ses_events`, AND `sqs_polling_enabled` — not
  two): `email_ses_events` is a feature flag ("is SES event tracking a
  thing here at all"), which belongs in `eligible?/1`, not folded into
  the polling toggle. Getting this split right is what lets the admin
  panel (P2) distinguish "Idle — no integration" (eligible? false) from
  "Off" (enabled? false) as genuinely different states.
  """

  @typedoc "A tracker module implementing this behaviour."
  @type t :: module()

  @doc """
  The discriminator — matches `SendProfile.provider_kind` (`"aws_ses"`, `"brevo_api"`, …).
  """
  @callback provider_kind() :: String.t()

  @doc """
  Human-readable name for the admin panel ("Amazon SES", "Brevo").
  """
  @callback label() :: String.t()

  @doc """
  Is there a working event source this tracker can poll right now? Folds
  every feature/source gate (integration presence, feature flags) —
  everything EXCEPT the operator's polling on/off switch.
  """
  @callback eligible?() :: boolean()

  @doc "The operator's polling master toggle only (not eligibility)."
  @callback enabled?() :: boolean()

  @doc """
  Run one poll cycle synchronously, outside of Oban's own scheduling —
  for callers that want an immediate, in-process cycle (e.g. a future
  admin panel "Poll now" action) rather than queueing a job. Delegates to
  the existing `*PollingJob.perform/1` logic; the self-scheduling job/
  worker itself is unchanged by this behaviour.
  """
  @callback poll_cycle(context :: map()) :: :ok | {:error, term()}

  @doc "Cadence (ms) the next self-schedule should use — the tracker's own configured interval."
  @callback interval_ms() :: pos_integer()

  @doc "The Oban worker module backing this tracker's self-scheduling chain."
  @callback worker() :: module()

  @doc """
  `eligible?() and enabled?()` — the single condition the reconciler
  enforces "exactly one chain" against. Not a callback (every tracker
  gets this for free from the two it does implement) — takes the tracker
  MODULE, not an instance, since trackers are stateless behaviours.
  """
  @spec should_run?(t()) :: boolean()
  def should_run?(tracker) when is_atom(tracker) do
    tracker.eligible?() and tracker.enabled?()
  end

  @typedoc "The admin panel's four-word state vocabulary (spec §5)."
  @type state :: :active | :idle_no_integration | :off | :stalled

  @doc """
  Derives the admin panel's State column — exactly one of `:active`,
  `:idle_no_integration`, `:off`, `:stalled` (spec §5).

  `:stalled` (`should_run?` true, zero jobs across
  `available|scheduled|executing`) is the one state that needs a false-
  positive guard: a healthy chain inserts its own successor
  *synchronously inside `perform`*, before returning, so at every point
  in a normal cycle at least one row is `executing` (the current job,
  which hasn't finished yet) or `scheduled`/`available` (its
  already-inserted successor) — never both empty at once. Counting
  `executing` (via `pending_jobs_count/1`) is what closes that window;
  without it, reading queued-only states would flicker `:stalled` on
  every single cycle. A transient miss beyond that (e.g. reconcile
  hasn't run yet since a `SendProfile` was just added — no PubSub for
  that today, spec §4.3) self-clears within one reconcile Cron tick;
  this function makes no attempt to mask that window client-side, since
  doing so would also hide a genuinely stalled chain.
  """
  @spec state(t()) :: state()
  def state(tracker) when is_atom(tracker) do
    cond do
      not tracker.enabled?() -> :off
      not tracker.eligible?() -> :idle_no_integration
      pending_jobs_count(tracker) > 0 -> :active
      true -> :stalled
    end
  end

  @doc """
  Oban job count for this tracker's `worker/0`, across exactly
  `available|scheduled|executing` — the "is a chain alive" health check
  (spec §5's "Queued" column and `state/1`'s `:stalled` detection both
  use this; **never** queued-only, see `state/1`'s moduledoc).
  """
  @spec pending_jobs_count(t()) :: non_neg_integer()
  def pending_jobs_count(tracker) when is_atom(tracker) do
    import Ecto.Query

    worker_name = inspect(tracker.worker())
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end

  @doc """
  Timestamp this tracker's chain last finished a cycle — derived
  generically from Oban's own job history (the last `completed` job for
  `worker/0`), not a per-tracker persisted setting, so it works
  uniformly for every registered tracker with zero extra plumbing. A
  no-op cycle (nothing to fetch) still completes normally, so this
  reads as "the chain is alive and ticking", matching what the existing
  per-provider `*_last_polled_at` settings already intended.
  """
  @spec last_polled_at(t()) :: DateTime.t() | nil
  def last_polled_at(tracker) when is_atom(tracker) do
    import Ecto.Query

    worker_name = inspect(tracker.worker())
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where: j.state == "completed",
      order_by: [desc: j.completed_at],
      limit: 1,
      select: j.completed_at
    )
    |> repo.one()
  rescue
    _ -> nil
  end
end
