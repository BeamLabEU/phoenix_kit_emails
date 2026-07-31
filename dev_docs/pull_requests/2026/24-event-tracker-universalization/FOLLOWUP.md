# Follow-up to the GLM review of PR #24

The review's Stage 1 `WRONG` was correct and reproducible, so it is fixed here
rather than argued with. Its two `MINOR`s are addressed; the perf `MINOR` is
recorded as a follow-up, not done.

## 1. The SQS queue URL is part of eligibility again (was: silent boot change)

`Supervisor.should_start_sqs_polling?/0`, which the merge deleted from the boot
path, required `has_sqs_configuration?/0` — a non-empty queue URL. Its
replacement, `SQSPollingManager.eligible?/0` →
`SQSPollingJob.pollable_ignoring_toggle?/0`, checked the system switch, SES
events and the sender-aware gate but **not** the queue URL.

So a deployment with SES credentials and `sqs_polling` on but no queue URL:

- started a chain at boot (the old boot started none),
- had the reconcile Cron resurrect it every two minutes,
- logged `validate_configuration/1`'s "SQS queue URL not configured" on the
  30 s misconfig backoff forever, and
- showed up in the admin panel as `:active` / "Running normally", because
  `state/1` sees live jobs.

`pollable_ignoring_toggle?/0` now includes `queue_url_configured?/0`, checked
before the sender-aware gate (a Settings read, no DB round trip). The same state
now reads `:idle_no_integration`.

Test fallout, all of it real: thirteen tests were asserting behaviour that
depended on SES being eligible with no queue configured. Two are worth calling
out:

- `sqs_polling_job_forced_test.exs` observed "the cycle was entered" through the
  *missing queue URL* error — which is now unreachable, because such a cycle is
  never entered. It provokes the same `validate_configuration/1` error with an
  out-of-range polling interval instead, still with no network call.
- `supervisor_boot_gates_test.exs` gained an explicit regression guard for the
  queue-URL-less state.

## 2. The boot-gate predicates delegate instead of duplicating

`should_start_sqs_polling?/0` and `should_start_brevo_polling?/0` were a second,
hand-written copy of the gate, and had already drifted from the tracker
callbacks in both directions: the SQS one omitted the sender-aware gate; the
Brevo one omitted the active-integration requirement. Both now delegate to
`EventTracker.should_run?/1` — the same call `EventTrackerReconciler.reconcile/0`
makes — so `supervisor_boot_gates_test.exs` asserts what boot does rather than
what it used to do.

One upstream expectation is deliberately inverted: its
"does not require active Brevo profiles (job no-ops each cycle)" case asserted
that boot seeds a chain for a toggle with no integration behind it, so that a
profile added later gets picked up without a manual re-toggle. With the reconcile
Cron running, a profile added later is picked up within one tick either way, so
there is no reason to run a chain that can only no-op — and the panel stays
honest (`:idle_no_integration`, not `:active`). The test now asserts the new
behaviour with that rationale inline.

## 3. The foreign-event skip path is observable

Per-event skips stay at `:debug` (on a shared account they can be the common
case), but each fetched page now logs one `:info` summary when anything was
skipped. As the review notes, this path is not purely foreign mail: an event for
*our own* mail also lands here when the send never recorded a provider
message_id, which previously surfaced as a loud `[SYNC ISSUE]` warning and now
would have been silent. A page that is suddenly all skips is the signal.

## 4. Recorded, not done

`build_rows/0` re-runs roughly four to five queries per tracker on every render
and every event. At the current two registered trackers this is not worth
optimizing; if the registry grows, batch the Oban counts into one grouped query
or cache rows between `update/2` and the trailing event rebuild.

## Verification

`mix compile --warnings-as-errors` clean; suite 222 tests, 0 failures with
`--include integration` (220 before, plus the two new guards).
