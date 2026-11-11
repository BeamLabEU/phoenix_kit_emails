# Code Review: PR #51 — Fix ?page and ?per_page crashing the emails and templates lists

**Reviewed:** 2026-11-11
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/51
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 70b96e1ac8f04e40fb3b603ed28e2f943daff8ba
**Status:** Merged

## Summary

Reviewed integer parsing, page clamping, column reordering, settings bounds,
and their callers and tests. The template list/editor has since been retired;
reviewed the surviving emails list and settings against the current tree.

## Issues Found

### 1. [BUG - MEDIUM] Nested URL filters still crash the emails list — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/emails.ex`, `apply_params/2`

The integer parameters are safe, but filters retained arbitrary decoded query
values. A URL such as `?from_date[nested]=value` reaches `Date.from_iso8601/1`
with a map. Other nested filters fail during query construction or when the
template encodes export links. Lists such as `?status[]=sent` also fail.
This is a remaining input-validation gap, not a regression introduced by #51.

Normalize all eight string filters with the existing `Utils.string_param/1`
before queries, assigns, and rendering. Invalid shapes become empty filters;
valid pagination and other filters are preserved. Added a map/list matrix for
each filter, exercising `handle_params/3` and rendering the resulting page.
All 16 cases failed before the fix and pass afterward.

**Confidence:** 100/100

## What Was Done Well

- The parser requires a complete integer and applies explicit caller bounds.
- Counts are calculated before clamping the page, including empty lists.
- Invalid settings input preserves the existing error paths.
- Existing tests cover malformed numbers, upper limits, and last-page behavior.

## Validation

See [the dated review report](../../../reports/2026-11-11-recent-changes-review.md)
for the complete suite and gate results, including dependency remediation.

## Verdict

Approved with fixes. Integer handling is sound; URL string filters now receive
the same boundary validation as event payloads.
