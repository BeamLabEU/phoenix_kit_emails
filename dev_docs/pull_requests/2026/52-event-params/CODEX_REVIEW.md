# Code Review: PR #52 — Refuse crafted event payloads instead of crashing, stop minting atoms in metrics

**Reviewed:** 2026-11-11
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/52
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** ea3500fa49c284cdd07b0a800acbbf3d7cf1511e
**Status:** Merged

## Summary

Reviewed the surviving LiveView event handlers and their render-after-event
tests: filters, selections, navigation, test sends, metrics periods/custom
ranges, and settings writes. Template editor code was removed in the later
core 3.0 migration, so it is not a current fix target.

## Issues Found

### 1. [BUG - MEDIUM] Direct URL loads bypassed string-filter validation — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/emails.ex`, `apply_params/2`

Event handlers filter malformed values before encoding a URL, but opening a
crafted URL directly bypassed those handlers. Its decoded maps/lists entered
the filters unchanged and crashed queries, date parsing, or rendering.

Applied `Utils.string_param/1` at the URL boundary too. The 16 regression cases
and reproduction are documented in the [PR #51 review](../51-page-param/CODEX_REVIEW.md).
This is the same finding across the two related PRs, counted once in the
dated review report.

**Confidence:** 100/100

## What Was Done Well

- Metrics now resolve only explicit period atoms; unknown names create no atoms.
- Custom date ranges use boolean handling compatible with `Date` values.
- Campaign/template query values are encoded before navigation.
- Malformed settings writes are refused rather than stored in render assigns.
- Tests render after events, catching failures deferred until HEEx evaluation.

## Validation

See [the dated review report](../../../reports/2026-11-11-recent-changes-review.md)
for complete suite and gate results.

## Verdict

Approved with fixes. The reviewed event guards remain effective, and direct URL
loads now validate the same string filters.
