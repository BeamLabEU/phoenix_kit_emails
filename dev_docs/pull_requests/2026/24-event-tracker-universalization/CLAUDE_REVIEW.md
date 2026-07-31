# Code Review: PR #24 — Universalize email event-tracking pollers: EventTracker behaviour, reconciler, unified admin panel

**Reviewed:** 2026-07-31
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/24
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a80000ebdd14751f3c8dcd2e046321098919e723
**Status:** Merged

## Summary

Turns the two hand-wired event pollers (SES/SQS and Brevo) into a single
lifecycle: an `EventTracker` behaviour every provider implements, a compile-time
`EventTrackerRegistry`, a stateless `EventTrackerReconciler` that enforces "iff
`should_run?/1`, exactly one self-scheduling Oban chain exists", a periodic
`EventTrackerReconcileWorker` Cron as the correctness backbone, and one
registry-driven "Delivery Event Tracking" admin panel replacing the polling
controls in the two per-provider settings sections. The supervisor's boot path
and its two boot-gate predicates now delegate to the same reconcile call instead
of duplicating the gate, and `BrevoPollingJob` gained a cheap existence check
that skips events for mail this app never sent (the shared-Brevo-account case the
PR branch was originally opened for).

The design is sound and the reasoning is unusually well documented in-tree. The
findings below are all in the seams between the new generic layer and the
provider-specific behaviour it replaced — three of them only surface in a real
deployment (a configured Pruner, a toggle click, a node that dies mid-cycle),
which is why the suite did not catch them.

## Issues Found

### 1. [BUG - MEDIUM] The panel's "Last poll" column reads "Never polled yet" for a healthy Brevo chain — FIXED

**File:** `lib/phoenix_kit/modules/emails/event_tracker.ex` lines 186–204 (pre-fix)

`EventTracker.last_polled_at/1` derives the timestamp exclusively from Oban's job
history — the newest `completed` row for `worker/0`:

```elixir
from(j in Oban.Job,
  where: j.worker == ^worker_name,
  where: j.state == "completed",
  order_by: [desc: j.completed_at],
  limit: 1,
  select: j.completed_at
)
```

`Oban.Plugins.Pruner` deletes `completed` rows older than `max_age`, **60 seconds
by default**. Brevo's interval *floor* is 30s (`min_interval_ms/0`), its shipped
default is 120s, and a real deployment runs it in minutes. So for Brevo the
completed job is almost always already pruned by the time anyone opens the panel,
and the column reports "Never polled yet" for a chain that is polling perfectly.
SES escapes this only by accident — its 5s cadence keeps a completed row inside
any sane prune window.

This is a regression against what the PR replaced. The deleted `BrevoEvents`
section rendered `BrevoPollingManager.status().last_polled_at`, sourced from the
durable `brevo_last_polled_at` setting that `BrevoPollingJob.run_cycle/1` still
writes on **every** cycle (including a no-op one — that write was added
deliberately for exactly this display). The generic derivation left that setting
with no reader on the panel path.

The moduledoc argued the derivation "works uniformly for every registered tracker
with zero extra plumbing", which is true, and independent of whether the data
survives long enough to read.

**Fix applied:** added `last_polled_at/0` as a fourth `@optional_callback` on
`EventTracker`, alongside the three the panel already routes through a guarded
wrapper. `EventTracker.last_polled_at/1` prefers it and falls back to the Oban
derivation for trackers that skip it, so SES is untouched and a future Mailgun
implementation gets the same free default. `BrevoPollingManager.last_polled_at/0`
reads the durable setting (parsing its ISO8601 string to `DateTime`, `nil` on an
unparseable value rather than raising into the panel). The Pruner bound on the
fallback is now documented on `last_polled_at/1` as the reason the callback
exists, so the next tracker author picks the right side.

Deliberately **not** done: persisting a `sqs_last_polled_at` setting to make SES
symmetric. SES polls every 5s by default — that is a Settings write plus cache
invalidation every five seconds, permanently, to improve a column that already
works for that tracker.

**Confidence:** 92/100

### 2. [BUG - MEDIUM] The panel's Tracking toggle bypasses the reconciler, so it can create the exact state the PR's own follow-up removed — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/delivery_event_tracking.ex` lines 47–66 (pre-fix)

`toggle_tracking` calls the manager directly:

```elixir
if tracker.enabled?(), do: tracker.disable_polling(), else: tracker.enable_polling()
```

`enable_polling/0` writes the setting **and inserts a chain unconditionally** — it
never consults `eligible?/0`. So toggling SES on while no queue URL is configured
queues a chain for a tracker that has nothing to poll: the panel renders "Idle —
no integration" beside a non-zero Queued count, and the job wakes, fails
`should_poll?/0`, and dies — but only after the row existed. That is precisely the
class of state `FOLLOWUP.md` §1 set out to eliminate at boot, re-introduced from
the UI. The disable direction has the mirror problem: the queued job is left in
place.

Both self-heal on the next reconcile Cron tick, so this is bounded at ~2 minutes —
**unless** the host never wired the `event_tracker_reconcile` queue and crontab
entry, in which case nothing ever cleans up and the panel stays inconsistent
indefinitely. That is not a hypothetical configuration: it is the default for
every install that predates this PR's installer change.

Notably, both the spec (§4.3, "a settings toggle" listed as a reconcile trigger)
and `EventTrackerReconciler`'s own moduledoc ("safe to call from anywhere — boot,
a settings toggle, the Cron tick, a future admin panel") describe this call site.
The panel is that admin panel, and it is the one caller that does not make the
call.

**Fix applied:** `toggle_tracking` now calls
`EventTrackerReconciler.reconcile_tracker/1` after a successful setting write, so
the same code path that owns the invariant everywhere else owns it here too.
Enabling an eligible tracker still starts its chain (the reconcile insert
conflicts harmlessly with the one `enable_polling/0` just made); enabling an
ineligible one leaves nothing queued; disabling cancels immediately instead of
after a Cron tick. Three regression tests added.

**Confidence:** 90/100

### 3. [BUG - MEDIUM] "Poll now" reports success for a tracker that cannot poll — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/delivery_event_tracking.ex` lines 68–84 (pre-fix)

The Poll now button renders for every row regardless of state. `poll_now/0`
inserts a `forced: true` job, which by design bypasses the operator's toggle but
**never** eligibility — `SQSPollingJob.perform/1` gates on `should_poll?() or
(forced? and pollable_ignoring_toggle?())`, and `BrevoPollingJob` likewise keeps
its profile gate. So on an `:idle_no_integration` row the click enqueues a job
that is guaranteed to wake up, fail its gate, log at `:debug`, and do nothing —
while the operator has been flashed "Amazon SES poll triggered".

The failure mode this creates is the one the button exists to prevent: an
operator verifying a freshly configured integration gets a green flash and no
data, with the only evidence at `:debug` level.

**Fix applied:** `poll_now` checks `eligible?/0` first and, when false, flashes
the State column's own `:idle_no_integration` hint instead of enqueueing.
Deliberately reuses that existing msgid rather than inventing a second wording for
the same condition — which also keeps this fix out of the gettext catalogues.
Two existing tests were relying on the ineligible path silently succeeding and now
set up a real integration first (closer to what they claim to test); a third
asserts the refusal.

**Confidence:** 88/100

### 4. [BUG - MEDIUM] An orphaned `:executing` job permanently blocks resurrection *and* masks it as "Active" — DOCUMENTED, not code-fixed

**File:** `lib/phoenix_kit/modules/emails/event_tracker_reconciler.ex` lines 119–141

`ensure_chain/1` includes `:executing` in its unique states — correctly, and for a
well-argued reason (without it, reconciling during a live cycle inserts a genuine
second chain). The consequence is that a job orphaned in `:executing` by a node
that died mid-cycle is a *permanent* unique conflict: reconcile can never insert a
successor, on this tick or any future one.

`EventTracker.state/1` counts `:executing` in `pending_jobs_count/1` too, so the
same orphaned row makes the panel report `:active` / "Running normally" for a
tracker that has stopped polling entirely. Every recovery affordance the panel
offers is neutralised at once: no `:stalled` badge, no Restart button (it only
renders for `:stalled`), and Restart would be a no-op anyway. Nothing inside this
package can observe the difference — an orphaned `executing` row and a live one
are the same row.

The correct fix lives in host configuration, not here: `Oban.Plugins.Lifeline` is
what returns orphaned rows to `:available`, after which everything behaves
normally. **Not code-fixed** because the alternatives are all worse — excluding
`:executing` from the unique states re-opens the double-chain hole the comment
documents, and an age heuristic in `state/1` would guess at what Lifeline already
knows authoritatively.

**Fix applied (documentation):** `Oban.Plugins.Lifeline` and `Oban.Plugins.Pruner`
added to the installer's printed `plugins:` snippet, with an explicit instruction
to **merge** that list rather than replace an existing one (the snippet as merged
would have silently dropped a host's Pruner if pasted verbatim — a second, quieter
problem, given `Queue.serialize/1` already warns that queued mail keeps full
message bodies in `oban_jobs` until pruned). `EventTrackerReconcileWorker`'s
moduledoc explains why Lifeline is load-bearing here rather than nice-to-have.

**Confidence:** 85/100

### 5. [BUG - LOW] The interval input rejects valid values in the browser

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/delivery_event_tracking.html.heex` lines 49–63 — FIXED

`min` and `step` were both bound to `row.min_interval_ms`. HTML `step` is relative
to `min`, so the browser only accepted `min + n × min`: for Brevo, 30s / 60s / 90s
and nothing between. Meanwhile `phx-blur` posts on blur regardless of validity and
`set_polling_interval/1` accepts anything `>= 30_000`, so typing 45000 saved
correctly while the field displayed as invalid.

**Fix applied:** dropped `step`; `min` was always the real constraint and is what
`min_interval_ms/0` was introduced for.

**Confidence:** 95/100

### 6. [OBSERVATION] The Brevo foreign-event skip silently disables `email_create_placeholder_logs` for that path — DOCUMENTED

**File:** `lib/phoenix_kit/modules/emails/brevo_polling_job.ex` (`process_known_email_event/2`)

The new existence check short-circuits ahead of `SQSProcessor`, including ahead of
`handle_placeholder_creation/5`. With `email_create_placeholder_logs` on (off by
default), polled Brevo events for unknown message ids used to create placeholder
log rows and now do not.

Verified the check mirrors the full lookup exactly — `find_email_log_by_message_id/1`
cascades `message_id` then `aws_message_id`, and
`Log.exists_by_any_message_id?/1` queries both — so no event the processor *would*
have matched is dropped. Only the placeholder branch changes.

Left as-is: on a shared account, "create a log for every orphaned event" means
materialising a row per foreign send, i.e. other senders' traffic in this app's
email log, which is the noise the PR exists to stop. Recorded in a comment at the
gate so the interaction is on record rather than accidental. SES, where every
event is by definition our own mail, keeps the setting's original behaviour.

**Confidence:** 90/100

### 7. [OBSERVATION] 24 newly-extracted msgids ship untranslated in ru/et

The `.pot`/`.po` regeneration picked up 46 msgids that had never been extracted
before. The PR's own new strings are fully translated in all three locales
("Delivery Event Tracking", "Idle — no integration", "Stalled", "Poll now", …);
the 24 untranslated ones are pre-existing UI strings that were previously missing
from the catalogue entirely ("Available Fields", "Not Configured", "Table columns
updated successfully", …).

Not a regression — those strings rendered in English before this PR and still do —
and inventing Estonian and Russian copy for unrelated UI is not a reviewer's call.
Recorded so it is a known gap rather than a surprise.

**Confidence:** 95/100

## Cross-checks that came back clean

- **Registry vs. the real source of truth.** `EventTrackerRegistry`'s two
  `provider_kind` values (`"aws_ses"`, `"brevo_api"`) are exactly the
  `:email_send`-capable keys in core's `Integrations.Providers` registry that have
  an event API. The third, `"smtp"`, correctly has no tracker.
- **The narrowed SES gate.** `pollable_ignoring_toggle?/0`'s new
  `queue_url_configured?/0` — the queue-URL precondition the merge dropped and
  a80000e restored — is checked at every call site that matters
  (`SQSPollingManager.eligible?/0`, `integration_count/0`, boot,
  `SQSPollingJob.perform/1`'s forced branch).
- **Boot gates vs. reconcile.** `should_start_sqs_polling?/0` and
  `should_start_brevo_polling?/0` now delegate to `EventTracker.should_run?/1`,
  the same call the reconciler makes, so the drift the follow-up describes cannot
  recur.
- **Dangling references.** No template or module still reads the assigns removed
  with the polling controls (`@sqs_polling_enabled`, `@brevo_polling_interval_ms`,
  `toggle_sqs_polling`, `toggle_brevo_events`); the deleted `BrevoEvents` section
  contained polling controls only, nothing stranded.
- **Translation loss.** No existing ru/et msgstr was blanked by the regeneration —
  every newly-empty entry is a newly-extracted msgid.
- **`state/1`'s `:stalled` window.** The false-positive analysis holds: a healthy
  chain inserts its successor synchronously inside `perform/1`, so counting
  `available|scheduled|executing` never observes both empty mid-cycle.

## What Was Done Well

- The `eligible?/0` vs `enabled?/0` split is the right decomposition, and the
  moduledoc explains *why* the old conflation was a bug rather than just asserting
  the new shape. It is what makes "Idle — no integration" and "Off" distinguishable
  states instead of one ambiguous "not running".
- Reconcile as plain idempotent functions with the invariant enforced at the
  database by Oban's own `unique`, rather than a GenServer orchestrator, is the
  correct call for a multi-node deployment — and the deliberate absence of
  `replace:` (with the reasoning for why adding it would silently clamp a
  10-minute Brevo interval to the ~2-minute Cron period) is the kind of decision
  that is expensive to rediscover later.
- The optional-callback wrappers (`integration_count/1`, `accounts/1`,
  `toggle_account_polling/2`) mean a future tracker cannot crash the panel by
  omitting the multi-account extras. That pattern is what made finding 1's fix a
  four-line addition rather than a redesign.
- `FakeEventTracker` lets the whole four-state matrix be asserted without SES or
  Brevo fixtures, and it defines none of the optional callbacks — so it is
  simultaneously the fixture proving the fallbacks work.
- The `.dialyzer_ignore.exs` entry is narrowly scoped, does not pin a line number,
  and records the verification that it is not masking a regression from this work.

## Verdict

**Approved with fixes.** The architecture is right and the migration is careful;
everything found was in the boundary between the new generic layer and the
provider-specific behaviour it subsumed. Findings 1, 2, 3 and 5 are fixed with
tests; finding 4 is a host-configuration hazard now documented at both the
installer and the worker; findings 6 and 7 are recorded trade-offs.

## Verification

`mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`,
dialyzer) passes, both before and after these changes.

The DB-backed suite could **not** be executed in this environment — no PostgreSQL
is available, so every `:integration`-tagged test (including the ones added here)
was excluded. They compile, and the assertions were written against the same
fixtures the existing tests in those files use, but they have not been run. The
author's own recorded run was 222 tests / 0 failures with `--include integration`.
