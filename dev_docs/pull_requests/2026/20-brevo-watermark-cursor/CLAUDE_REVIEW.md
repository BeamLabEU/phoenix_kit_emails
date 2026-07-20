# Code Review: PR #20 — Brevo poller: date+offset watermark cursor

**Reviewed:** 2026-07-20
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/20
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 551448718df556ec2b6c3ee520ce652a3423eec6
**Status:** Merged (fc4b10e)

## Summary

Replaces `BrevoPollingJob`'s fixed `[yesterday, today]` re-fetch-from-offset-0
window with a persisted per-integration `%{date, offset}` watermark
(`Emails.get_brevo_watermark/1` / `set_brevo_watermark/3`, stored via
`PhoenixKit.Settings`' JSON-by-prefix helpers). Adds a trailing one-day
safety re-check (own small page budget, gated on `watermark.date == today`)
to cover Brevo's indexing lag / undocumented `startDate` timezone, and prunes
watermarks for integrations no longer active. The PR itself already includes
a self-review round (`5514487`, pushed before merge) that capped the
trailing re-check's own budget, deduplicated the page-fetch code between the
forward walk and the re-check, and added failure logging to watermark
persistence.

## Issues Found

### 1. [BUG - HIGH] Today's watermark offset never advances past a non-empty short page — FIXED
**File:** `lib/phoenix_kit/modules/emails/brevo_polling_job.ex`, `advance_watermark/7` → `advance_past_short_page/7` (around lines 453–503 pre-fix)

`advance_watermark/7`'s full-page branch correctly advances the offset:
`new_offset = offset + limit`. Its short-page branch, however, called
`advance_past_short_page(..., offset, ...)` with the **pre-fetch** offset —
not `offset + length(events)`. `advance_past_short_page/7`'s
`date >= today` branch (today never "closes", so this is the common path
for every cycle) then persists that unchanged, pre-fetch offset:

```elixir
else
  persist_watermark(integration_uuid, date, offset)  # `offset` = pre-fetch position
end
```

Concretely: watermark at `{today, 5}`; next fetch at offset 5 returns 2
events (a short page, since 2 < limit). The correct next watermark is
`{today, 7}` — but the code persisted `{today, 5}` again. Every subsequent
cycle re-fetches from offset 5, re-getting the same 2 (now stale) events
plus whatever's new, forever, for as long as today's total event count
stays under the page limit — which, at the default limit of 2500, is
effectively *every* cycle for a normal-volume sender. This defeats the
watermark's own stated purpose for the one day it's polled most often:
"every already-processed event pays the full re-fetch + dedup-lookup cost
again" (the exact problem this PR set out to fix) still happens, just
silently, for today's tail.

Not a data-loss bug — `Event.create_event/1`'s dedup guarantee (noted
extensively in the moduledoc) absorbs the reprocessing safely — but it's a
real efficiency/completeness regression against the PR's own design goal,
and none of the PR's tests caught it: the only "short page for today" test
(`"the watermark never leaves today, even when today's own page comes back
short"`) uses **zero** events, where `offset` and `offset + length(events)`
are numerically identical and the bug is invisible.

**Fix:** call site now passes `offset + length(events)`, with a comment
explaining why the pre-fetch offset is wrong there. Also fixed the (now
stale) cap-hit `Logger.warning` in `advance_watermark/7`'s exhausted-budget
clause, which always cited `@max_pages_per_integration` (10) even when the
actual budget for that call was smaller (`@max_pages_per_integration -
trailing_pages`, e.g. 8) — misleading for an operator diagnosing lag.
**Confidence:** 95/100

## What Was Done Well

- The watermark-per-day design (never a growing window) is the right fix
  for the stated day-boundary bug in a naive "just remember the offset"
  approach — correctly reasoned through in the moduledoc.
- Per-page persistence (not per-cycle) bounds crash-replay to one page,
  and is verified by a dedicated test (`"a failed page fetch leaves the
  watermark exactly at the last successfully-processed page..."`).
- The trailing re-check's own separate, small page budget (added in the
  PR's own self-review round, `5514487`) correctly prevents a large
  backlog day from starving the forward walk — verified by test.
- Stale watermark cleanup (`prune_stale_watermarks/1`) is scoped correctly
  against the current active-integration set and tested for both the
  deleted-integration and excluded-integration cases.
- Extensive, honest moduledoc — documents trade-offs (e.g. the trailing
  re-check's own budget cap meaning a late event past a huge yesterday
  still isn't caught) rather than glossing over them.

## Verdict

**Approved with fixes.** The core watermark design is sound and well
reasoned; the one bug found undercut a central goal of the PR for the
highest-traffic day (today) specifically, but is a clean, narrowly-scoped
fix with a regression test now covering the previously-blind case (a
non-empty short page).

## Note on validation

`mix test` could not be executed in this environment — no local
PostgreSQL is available in this sandbox (no root/apt access to install
one) — so the new regression test (`"a non-empty short page for today
advances the offset past its own events"`) is unverified by an actual test
run; it was traced by hand against the fixed code path instead. `mix
precommit` (compile --warnings-as-errors, credo --strict, dialyzer, format)
was run and is the substitute gate — see report for its result.
