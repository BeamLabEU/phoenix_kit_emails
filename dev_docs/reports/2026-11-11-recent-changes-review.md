# Recent changes and PR review — 2026-11-11

**Reviewer:** Codex (GPT-6)
**Starting commit:** `92683e71c302b476c6b4432012c9825ae98aaa0a`

## Scope

Pulled `main` with `--ff-only`; it was already current. GitHub had no open PRs.
Recent PRs #53–#61 already had Codex reviews. Reviewed the surviving changes
from #51 and #52, which had only Claude reviews, plus the direct core 3.0
preparation commits: standalone migration checks, expected-schema manifest,
database-template retirement, dependency floor, and the recent lockfile.
Rechecked #61's retained-table tests through the full suite.

This pass covers recent changes and their current callers; it does not claim
a new review of every historical PR in the repository.

## Findings and fixes

### 1. [BUG - MEDIUM] Legacy template checks ignored the configured schema — FIXED

**Introduced in:** `b214097` (Retire the database layer for email templates)
**Files:** `lib/phoenix_kit/modules/emails/templates.ex` and `template_export.ex`
**Confidence:** 100/100

Both `Templates.legacy_table_exists?/0` and `TemplateExport.active_template/1`
probed an unqualified table name with `to_regclass`. Ecto queries instead use
the template schema's compile-time PhoenixKit prefix. A named-schema host
whose search path omits that schema therefore falsely reports no retained
templates, returning an empty export or no active row. A same-named table on
the search path can also make the probe disagree with the subsequent query.

The existence check now defaults to `Template.__schema__(:prefix)` and uses
parameterized, quoted identifiers in PostgreSQL. An explicit prefix checks
only that namespace; a nil prefix preserves Ecto's search-path behavior.
`active_template/1` reuses this check rather than maintaining a duplicate.
Database regressions cover a hidden schema whose name includes spaces and a
quote, an unrelated/missing schema with a visible table elsewhere, and nil
prefix listing/active-row lookup through the search path.

### 2. [BUG - MEDIUM] Nested query filters crashed the emails list — FIXED

**Related PRs:** [#51](https://github.com/BeamLabEU/phoenix_kit_emails/pull/51),
[#52](https://github.com/BeamLabEU/phoenix_kit_emails/pull/52)
**File:** `lib/phoenix_kit/modules/emails/web/emails.ex`, `apply_params/2`
**Confidence:** 100/100

Numeric URL parameters and event payloads were guarded, but the eight string
URL filters still accepted decoded maps/lists. Requests such as
`?search[nested]=value`, `?status[]=sent`, or `?from_date[nested]=value` failed
in query construction, date parsing, or export-link rendering.

Normalize these filters with the existing `Utils.string_param/1` at URL load.
Added 16 regressions, one map and one list for each filter, that run both
`handle_params/3` and rendering. All 16 failed before the change. This is a
remaining validation gap around those PRs, not a newly introduced regression.

### 3. [BUG - HIGH] Locked dependencies failed the security gate — FIXED

**File:** `mix.lock`
**Confidence:** 100/100

The initial `mix precommit` stopped at `mix hex.audit`: six advisories affected
four locked packages, including a critical certificate-hostname matching
advisory in `ssl_verify_fun` and a high-severity Ecto query-cache advisory.
Updated only these packages within the existing dependency constraints:

| Package | Before | After |
|---|---|---|
| `ecto` | 3.14.2 | 3.14.3 |
| `phoenix_html` | 4.3.0 | 4.4.0 |
| `saxy` | 1.6.1 | 1.7.0 |
| `ssl_verify_fun` | 1.1.7 | 1.1.9 |

This updates the repository's resolved dependencies. A library's lockfile does
not constrain a host application's resolution; hosts must update their own
lockfiles as well.

## Validation

- Baseline: **12 doctests, 860 tests, 0 failures**.
- The new URL-filter matrix reproduced **16 failures before the fix**.
- Focused URL/export database tests after fixes: **38 tests, 0 failures**.
- Full suite after fixes and dependency updates: **12 doctests, 879 tests,
  0 failures**, including database integration, manifest/repair, and retained
  legacy-table migration checks.
- Isolated configured-prefix verification: recompiled the template schema and
  readers with `prefix_export_review`, confirmed listing and active-row lookup
  read that schema's content while different public content remained visible,
  then removed the prefixed table and confirmed public rows did not mask its
  absence. All database changes were rolled back.
- `mix precommit`: **passed**. Compilation with warnings as errors, unused
  dependency check, Hex audit, format check, strict Credo, and Dialyzer ran.
  Audit reports no retired or security advisory packages. Dialyzer reports
  **Total errors: 2, Skipped: 2, Unnecessary Skips: 0**, covered by the existing
  Gettext filter; no suppressions were added.
- `git diff --check`: passed.

The default test database still has core marker V224, below core 3.0's V225
floor. It was not reset. All database validation ran in an independently
created `phoenix_kit_emails_review_20261111` database, removed after validation.

## Verdict

Approved with fixes. All validation passed. No version, changelog, tag, release,
or host configuration change is part of this review.
