# Code Review (second pass): PR #21 — Pollers: Oban unique/replace

**Reviewed:** 2026-07-26
**Follow-up fixed:** 2026-07-27 (0.1.18)
**Reviewer:** Grok (grok-4.5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/21
**Author:** timujinne
**Head / post-fix:** f102dae (merge b16bc0a) + review fix 65c653a (0.1.17) + boot/docs/tests (0.1.18)
**Status:** Merged; post-merge fixes in 0.1.17 and 0.1.18

## Relationship to CLAUDE_REVIEW.md

This is an independent recheck of the same change after Claude's review and the
0.1.17 follow-up. It does **not** re-litigate the Oban uniqueness design — that
was verified well against Oban 2.23 (worker-level `[:scheduled]` only,
`:executing` self-conflict, `schedule_in: 0` load-bearing for `replace:`, args
namespacing for forced jobs). Agrees with Claude's verdict and with the two
MEDIUM fixes that shipped.

## Claude findings — recheck

| # | Severity | Status | Recheck |
|---|----------|--------|---------|
| 1 | BUG - MEDIUM | FIXED (0.1.17) | Confirmed fixed: SQS `insert_forced_poll_job/0` + `forced? and pollable_ignoring_toggle?()`; forced bypasses only `sqs_polling_enabled`; chain does not resurrect (`sqs_polling_job_forced_test.exs`) |
| 2 | BUG - MEDIUM | FIXED (0.1.17) | Confirmed fixed: forced args keep a separate uniqueness namespace; manager tests assert regular tick's `scheduled_at` is untouched |
| 3 | NITPICK | FIXED (0.1.17) | Confirmed: `amazon_ses_sqs.ex` toggle comment matches current behaviour |
| 4 | OBSERVATION | NOT FIXED | Agree it is real; severity lower than it reads (see below) |
| 5 | OBSERVATION | NOT FIXED | Agree; vanishingly rare under concurrency 1 + unique; not worth a dead test branch |

### Note on #4 (pending job after disable)

`status().pending_jobs` still counts the draining row. The **admin settings UI
does not render `pending_jobs`** (Brevo shows last-polled / profile counts only;
SQS settings section does not surface manager status either). So this is mostly
an API/observability quirk (`Supervisor.system_status/0`, iex), not a visible
settings-panel regression. Still worth knowing if anything starts displaying it.
Deliberately left open — cancel-on-disable is optional UX, not a correctness gap.

## Additional findings

### 1. [NITPICK] Misleading Brevo manager `@moduledoc` on `poll_now/0` — FIXED (0.1.18)

**File:** `lib/phoenix_kit/modules/emails/brevo_polling_manager.ex`

Said `poll_now/0` forces a cycle "**regardless of the sender-aware gate**". Real
contract: bypasses `brevo_events_enabled` only; still respects
`Emails.enabled?/0` and the profile gate (empty → no-op cycle).

**Fix applied:** moduledoc rewritten to match `poll_now/0`'s `@doc` and
`BrevoPollingJob.perform/1`.

**Confidence:** 95/100

### 2. [NITPICK] Stale test name still claims disable cancels jobs — FIXED (0.1.18)

**File:** `test/phoenix_kit/modules/emails/brevo_polling_manager_test.exs`

Renamed to `"disable_polling/0 clears the setting"` (mirrors SQS).

**Confidence:** 100/100

### 3. [NITPICK] Brevo `poll_now` while-disabled test does not lock in forced args — FIXED (0.1.18)

**File:** same manager test

Now asserts `job.args == %{"forced" => true}` on the disabled-path insert,
matching SQS.

**Confidence:** 90/100

### 4. [OBSERVATION] No Brevo "forced does not resurrect the chain" perform test — FIXED (0.1.18)

**File:** `test/phoenix_kit/modules/emails/brevo_polling_job_test.exs`

Added `"a forced run does not resurrect the self-scheduling chain"` — after a
forced perform with the toggle off, no `available`/`scheduled` row remains.

**Confidence:** 85/100

### 5. [IMPROVEMENT - MEDIUM] Brevo has no boot-time chain starter (SQS does) — FIXED (0.1.18)

**File:** `lib/phoenix_kit/modules/emails/supervisor.ex`

After a clean restart, if the Brevo chain was already dead while
`brevo_events_enabled` stayed `true`, polling stayed dead until someone hit
enable or Poll now. SQS self-healed that case on every boot.

**Fix applied:**
- `should_start_brevo_polling?/0` — `Emails.enabled?() and Emails.brevo_events_enabled?()`
  (zero profiles allowed; job no-ops and still records `last_polled_at`)
- `should_start_sqs_polling?/0` — renamed/extracted from the old private
  `should_start_oban_polling?/0` (same predicate)
- Single boot Task waits for Oban, then `maybe_start_sqs_polling/0` and
  `maybe_start_brevo_polling/0` each call the matching manager's
  `enable_polling/0` (unique/replace collapses into an already-queued tick)
- `system_status/0` now also reports `brevo_polling_status`
- Gates unit-tested in `supervisor_boot_gates_test.exs`

**Confidence:** 88/100

### 6. [IMPROVEMENT - LOW] `set_polling_interval/1` does not move the next tick — NOT FIXED

Both managers only persist the setting. An already-queued successor keeps its
old `scheduled_at` until it fires. Optional product polish with unique/replace;
not a regression from #21. Left open.

**Confidence:** 80/100

### 7. [IMPROVEMENT - LOW] Cancel-only on `disable_polling/0` — NOT FIXED

Cancel without a following insert would make disable snappy and drop
`pending_jobs` to 0 without reintroducing the delete-then-insert race. Optional
UX; left open (see Claude #4).

**Confidence:** 82/100

### 8. [IMPROVEMENT - MEDIUM] Shared insert helper — NOT FIXED

Would reduce SQS/Brevo drift on the next uniqueness tweak. Optional refactor;
left open after the boot/docs/test batch.

**Confidence:** 75/100

### 9. [OBSERVATION] `schedule_next_poll/1` returns `:ok` on insert failure — NOT FIXED

Chain dies until boot re-seed (now both pollers) or manual enable. Pre-existing;
boot starter for Brevo substantially reduces the operational impact. Left open.

**Confidence:** 70/100

## What still looks solid

- Worker-level unique design and the moduledoc rationale remain correct.
- Forced args namespace is the right fix for both "run while disabled" and
  "don't reset cadence".
- `schedule_next_poll/1` always inserts `%{}` (never forced args) — so a forced
  run while the toggle is **on** extends the regular chain, not a forced chain.
- Self-heal of transient double chains (enable racing an executing cycle) still
  holds.
- Both pollers now boot-heal; forced paths and non-resurrection are covered on
  both sides.

## Testing note (unchanged)

Integration tests are `@moduletag :integration` / DataCase and need Postgres.
This environment may still skip them. Run against a real test DB before
trusting the new manager/forced/boot-gate suites.

## Verdict

**Agree with Approved with fixes** for the PR itself.

| Release | What closed |
|---------|-------------|
| **0.1.17** | Claude #1–#3 (SQS forced + cadence + stale comment) |
| **0.1.18** | Grok #1–#5 (Brevo boot starter, docs, test parity) |

Still open (low priority / optional): pending-job UX after disable, interval
reschedule, shared insert helper, insert-failure chain death. None block
shipping 0.1.18.
