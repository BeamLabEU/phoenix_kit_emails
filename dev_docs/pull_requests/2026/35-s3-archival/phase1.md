# PR #35 Phase 1 Review — phoenix_kit_emails
**Title:** emails: S3 archival, from placeholder to a feature that runs
**Author:** Tymofii Shapovalov (timujinne)
**Reviewed by:** Pincer 🦀
**Date:** 2026-08-14
**Verdict:** APPROVE (with pre-merge notes)

---

## Summary

This PR completes the S3 archival feature that has been disabled/badged "In
development" since the email sending audit. The entry point (`Emails.archive_to_s3/1`)
previously selected rows and returned them untouched — it never touched S3. Five
silent defects and one design hazard were fixed in the process of wiring it up:

1. **Events silently dropped** — `Log` derives `JSON.Encoder` with `except: [..., :events]`;
   the old code put events on exactly that key. Fixed by writing events beside the log,
   not inside it. Bonus: N+1 queries eliminated (one batch query instead of one per log).
2. **Body mislabeled as gzip** — `content_type: application/gzip` + `content-encoding: gzip`
   over an uncompressed body. Any S3 client honouring those headers would fail to gunzip
   plain JSON/CSV. Fixed to `application/json` / `text/csv` per format.
3. **Upload signed with nothing** — relied on ambient `config :ex_aws`, which is empty on
   installs that moved AWS keys into Integrations. Fixed via `AwsIntegrations.resolve_credentials/1`;
   falls back to ExAws chain for env/instance-role deployments.
4. **Blank bucket treated as a bucket** — `if bucket do` passed on `""`. Fixed by
   `setting_or_nil/1` which trims and returns nil on empty.
5. **`:parquet` format raised** — documented but no matching clause. Doc updated; clause removed.
6. **Design hazard: archival/cleanup race** — both jobs shared `email_retention_days` as
   cutoff; whichever ran first won. Cleanup now skips unarchived rows while archival is on.

New additions: `ArchiveWorker` (hourly Oban cron), `archived_at` + `s3_key` migration
columns + partial index, settings UI controls for bucket and credentials.

---

## Findings

### Blockers

None.

### Non-blockers

**1. No version bump / no CHANGELOG entry (pre-merge requirement)**
`mix.exs` still reads `@version "0.3.0"` and CHANGELOG has no entry for PR #35's
changes. The PR is draft ("Draft until review lands") — these must be done before
merge/release. Migration V2 is present and may warrant a minor bump (0.4.0) depending
on how the team treats schema changes.

**2. `s3_connections/0` lists only `aws_ses`-typed integrations**
An operator who set up a separate AWS IAM connection under a different integration
type would not see it in the credentials dropdown. The code comment acknowledges the
intent (every AWS connection, including accounts that don't send mail), and `aws_ses`
is the type used for all AWS integrations in this system — so in practice it's correct.
Worth noting if a generic-AWS integration type is ever added.

### Nitpicks

**1. `archive_loop` is recursive over potentially large backlogs**
The function is properly tail-recursive (Elixir/Erlang handles this without stack
overflow), so no issue in practice. Worth a glance if the batch_size default of 500
ever changes significantly.

**2. `s3_archived_size_mb` uses a 2 KB/row estimate**
Acknowledged in code comments. The number is "order of magnitude" and is consistent
with `calculate_storage_size_mb`. Acceptable.

**3. No bucket-name format validation**
S3 bucket names have rules (3–63 chars, lowercase, no underscores, etc.). An invalid
name only fails at upload time. Acceptable for now; operators are expected to know
their bucket names.

---

## Correctness Notes

**Idempotency:** Solid. `Log.mark_archived/3` only stamps rows where `archived_at IS NULL`,
so a second pass can't overwrite the s3_key of an already-uploaded batch. The `archive_loop`
stops on a failed batch rather than retrying the same rows endlessly.

**`archive_batch_to_s3` return value:** Confirmed (line 533 in PR branch) — returns
`length(logs)` in the success branch, which is what `archive_loop` accumulates. The diff
context was truncated and this line did not appear in the diff; it was not removed.

**Failure isolation:** S3 unavailable → archival Oban job fails and retries (max 3).
Email sending is a separate queue and is completely unaffected. Configuration errors
(`:s3_not_configured`, `:no_bucket_configured`) return `:ok` from the worker — logged
as warnings, do not burn retry attempts. Correct.

**Cursor strategy:** `archive_loop` pages on the `archived_at` stamp instead of holding
an open transaction/cursor. Each batch is its own short unit: select → upload → stamp.
This avoids holding a long-lived transaction over the busiest table in the schema.

**Cleanup coordination:** `Log.cleanup_old_logs/2` now accepts `require_archived: true`
when archival is on. The guard is not added when archival is off — confirmed by an
explicit test case ("with archival off, cleanup is unchanged and deletes regardless").

**Security:** Credentials come from the Integration system (`AwsIntegrations.resolve_credentials`)
or fall through to ExAws's own resolution chain. No hardcoded credentials anywhere.
Bucket name and integration UUID are stored as application settings (same path as all
other operator-managed settings). No public bucket exposure risk from the application code.

**Tests stop at the network boundary** — no `ExAws.request/2` call is exercised. The PR
body argues (correctly) that every defect listed above was decided before a byte was
sent; the tests pin exactly those decisions. `prepare_archive_data/3`, `s3_request_config/0`,
and `content_type/1` are public `@doc false` specifically to make this testable.

---

## Stats
- **Tests:** 22 new (437 total, 0 failures, gate passed: compile --warnings-as-errors, credo --strict, dialyzer clean, format clean, gettext up to date)
- **Migrations:** V2 — `archived_at` (timestamptz, nullable), `s3_key` (text, nullable), partial index on `archived_at IS NOT NULL`. Safe: no defaults required, existing rows are genuinely "never archived".
- **Version bump:** Not in PR (pre-merge item; draft PR)
- **Dependency changes:** No new deps — `ex_aws_s3 ~> 2.4` was already present in `mix.exs`
- **Files changed:** 16 (+1,458 / -286)
