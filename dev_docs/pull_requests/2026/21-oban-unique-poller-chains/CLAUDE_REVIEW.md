# Code Review: PR #21 — Pollers: Oban unique/replace instead of delete-then-insert

**Reviewed:** 2026-07-26
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/21
**Author:** timujinne
**Head SHA:** f102dae (merged as b16bc0a)
**Status:** Merged

## Summary

Replaces the manual `delete_queued_jobs/0` + insert dance in both polling
chains (`SQSPollingJob`, `BrevoPollingJob`) with Oban's own uniqueness:

- Worker-level `unique: [period: :infinity, states: [:scheduled]]` on both
  workers, so a self-rescheduling job can never fork the chain.
- Per-call `unique: [period: :infinity, states: [:available, :scheduled]]`
  + `replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]` on
  the managers' immediate inserts, so `enable_polling/0` collapses into an
  already-queued tick (moved to run now) instead of appending a second row.
- Drops `cancel_scheduled/0` from both jobs and the `disable_polling/0`
  cancellation calls — the queued job's own `should_poll?/0` check lets the
  chain die within one cycle.
- `schedule_next_poll/1` promoted from `defp` to `def` (`@doc false`) so the
  dedup is directly unit-testable; new tests for both jobs and both managers.
- New `%{"forced" => true}` args for `BrevoPollingManager.poll_now/0`, with a
  `forced?` bypass in `BrevoPollingJob.perform/1`.

The design reasoning in the moduledocs was verified line-by-line against the
vendored Oban 2.23.0 source and holds up (see "What Was Done Well").

## Issues Found

### 1. [BUG - MEDIUM] `SQSPollingManager.poll_now/0` is a silent no-op while polling is disabled — FIXED

**File:** `lib/phoenix_kit/modules/emails/sqs_polling_manager.ex` (`poll_now/0`,
`insert_poll_job/0`), `lib/phoenix_kit/modules/emails/sqs_polling_job.ex` (`perform/1`)

The PR added the `forced` concept to the Brevo half and documents the two
managers as mirrors of each other, but the SQS half kept sharing
`insert_poll_job/0` (args `%{}`) between `enable_polling/0` and `poll_now/0`.
`SQSPollingJob.perform/1` gates the whole cycle on `should_poll?/0`, which
includes `Emails.sqs_polling_enabled?/0` — so a manual poll while the toggle
is off inserts a job that runs, sees polling disabled, and does nothing.

That is precisely the case the manager thinks it is handling:

```elixir
unless polling_enabled?() do
  Logger.warning("SQS Polling Manager: Polling is disabled, but executing manual poll")
end
```

The log claims a poll happens; none does. The PR's new test
(`"poll_now/0 inserts an immediate job even while polling is disabled"`)
asserts only that a row is inserted, so the no-op reads as covered behaviour.

**Fix applied:** mirrored the Brevo design.
`SQSPollingManager.insert_forced_poll_job/0` inserts `%{"forced" => true}`,
and `SQSPollingJob.perform/1` now takes `args` and runs the cycle when
`should_poll?() or (forced? and pollable_ignoring_toggle?())`. `should_poll?/0`
was split so the forced path bypasses **only** the `sqs_polling_enabled`
toggle — never `Emails.enabled?/0`, the SES-events switch, or the
sender-aware profile gate — matching Brevo, where `forced?` bypasses
`brevo_events_enabled` but not `Emails.enabled?/0`. `schedule_next_poll/1`
still re-checks `should_poll?/0`, so a forced run while the toggle is off
runs exactly once and does not resurrect the chain.

**Confidence:** 95/100

### 2. [BUG - MEDIUM] `SQSPollingManager.poll_now/0` hijacked the regular chain's next tick — FIXED

**File:** `lib/phoenix_kit/modules/emails/sqs_polling_manager.ex` `insert_poll_job/0`

Same root cause as #1: because `poll_now/0` reused `insert_poll_job/0`, its
args matched the regular chain's (`%{}`), so its
`unique: [:available, :scheduled]` + `replace: [scheduled_at]` **conflicted
with the regular chain's already-scheduled tick and moved that job's
`scheduled_at` to now** — resetting the polling cadence on every manual poll,
and returning the regular chain's row rather than a new job.

The PR's own Brevo comment names this as the bug the distinct args namespace
fixes ("the old `cancel_scheduled/0`-based `poll_now` did NOT have this
property … This is a behavior fix, not just a mechanical port") — the SQS half
just never got the fix.

**Fix applied:** covered by the separate `insert_forced_poll_job/0` from #1.
Different args ⇒ separate uniqueness namespace ⇒ repeated `poll_now/0` calls
still collapse into one row, but never touch the regular chain.

**Confidence:** 95/100

### 3. [NITPICK] Stale comment: "disable_polling/0 … cancels scheduled jobs" — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/amazon_ses_sqs.ex` line 105

The toggle handler's comment still described the removed cancellation. Updated
to describe the current behaviour (flag cleared; the queued job's own
`should_poll?/0` check ends the chain on its next tick).

**Confidence:** 100/100

### 4. [OBSERVATION] `disable_polling/0` leaves one queued job visible in the status panel — NOT FIXED

**Files:** both managers' `disable_polling/0` and `status/0`

`count_pending_jobs/0` counts `available`/`scheduled`/`executing` rows, so
right after toggling polling off the admin settings panel reports
`pending_jobs: 1` for up to one full interval (the Brevo interval can be
minutes) while the toggle reads "off". Harmless — the job fires once and
no-ops — but it is a real, if minor, UX regression versus the old immediate
DELETE.

Deliberately not fixed: re-adding a targeted cancel would reintroduce exactly
the delete-then-insert coupling this PR set out to remove, for a cosmetic
gain. Recorded here so the trade-off is on file.

**Confidence:** 90/100

### 5. [OBSERVATION] A lost unique advisory lock is indistinguishable from a real conflict — NOT FIXED

**Files:** `sqs_polling_job.ex` / `brevo_polling_job.ex` `schedule_next_poll/1`

In Oban 2.23's `Oban.Engines.Basic.insert_unique/3`, failing to take the
`pg_try_advisory_xact_lock` short-circuits to:

```elixir
{:error, :locked} ->
  with {:ok, job} <- Changeset.apply_action(changeset, :insert) do
    {:ok, %{job | conflict?: true}}
  end
```

i.e. `{:ok, %Oban.Job{conflict?: true, id: nil}}` with **nothing persisted**.
`schedule_next_poll/1` treats every `conflict?: true` as "next tick already
exists" and returns `:ok`, so in that race the chain would end silently.

Not fixed, and not a regression — the pre-PR code fell into the `{:ok, _job}`
branch and logged success on the same path. Contention requires two concurrent
inserts with the *same* lock key (identical worker/args/states), which the
queue's concurrency of 1 plus the new uniqueness already makes vanishingly
unlikely. Guarding on `id: nil` would add a branch that cannot be exercised by
the suite.

**Confidence:** 80/100

## What Was Done Well

Every non-obvious claim in the new moduledocs checks out against the vendored
Oban 2.23.0 source — this is unusually well-grounded work:

- **`[:scheduled]` really is the only warning-free partial states list.**
  `Oban.Job.warn_unique/1` special-cases it by name; any other partial list
  trips the "missing incomplete states" warning and therefore
  `--warnings-as-errors`.
- **`:executing` really would self-conflict.** `Basic.unique_query/1` builds a
  plain `where state in ^states` query with no self-exclusion, so a job that
  inserts its successor from inside `perform/1` would match its own row. The
  chain would stall every cycle, exactly as documented.
- **`schedule_in: 0` really is load-bearing.** `resolve_conflict/4` does
  `Map.take(changeset.changes, keys)`; without an explicit schedule option
  `:scheduled_at` never enters `changes`, so `replace:` would silently copy
  nothing. `put_scheduling/2` + `normalize_state/1` also confirm the resulting
  job lands in `"scheduled"` (not `"available"`), as the comment says.
- **Args-based uniqueness namespacing works as claimed.** `unique_field/2`
  emits `args <@ '{}'` for the empty-args chain and `@>`/`<@` for the forced
  job, so the two can never match each other.
- The transient double-chain window (an `enable_polling` insert reaching
  `:available` before the executing job's `schedule_next_poll` fires) is
  self-healing: the second chain's next insert conflicts and merges. Traced
  through; no fix needed.
- Tests cover the two properties that actually matter — "twice ⇒ one row" and
  "an `:executing` row does not block the successor" — for both pollers.

## Testing Note

`mix test` in this environment: **35 passed, 0 failures, 91 excluded** — no
PostgreSQL is reachable here, so every `PhoenixKitEmails.DataCase` test
(`@moduletag :integration`) is skipped. That includes all four test files this
PR added and the three added by this review. They were written against the
existing DataCase patterns but have **not been executed**; they need a run
against a real test DB. `mix precommit` (compile `--warnings-as-errors` +
format + credo --strict + dialyzer) is clean.

## Verdict

**Approved with fixes.** The core change is correct and the reasoning behind
it is verifiably accurate against Oban 2.23. The gap was symmetry: the Brevo
half received a genuine behavioural fix (`forced` args) that the SQS half —
which shares the same manager shape and the same `poll_now/0` contract — did
not, leaving SQS's manual poll both a no-op when disabled and a cadence-reset
when enabled. Both are now fixed, with tests.
