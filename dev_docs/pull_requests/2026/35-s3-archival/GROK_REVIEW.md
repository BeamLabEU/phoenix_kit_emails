# Code Review: PR #35 — emails: S3 archival, from placeholder to a feature that runs

**Reviewed:** 2026-08-14
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/35
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** da1e83028a2b7384d9c06d82e96c2f587b5aa6e8 (merge)
**Status:** Merged; post-merge fixes on main

## Summary

Wires the existing `Archiver` (previously called by nothing) to
`Emails.archive_to_s3/2`, adds `archived_at` + `s3_key` (Migrations V2) so a
run is resumable, introduces `ArchiveWorker` as an hourly Oban Cron tick, and
exposes the bucket + credentials on the Email Tracking settings section.

The defects the author already found and fixed in-branch are real and the
fixes are the right shape:

- events written *beside* the log (the encoder skips `:events`)
- content-type matches the uncompressed body
- credentials from a chosen Integration, empty list falling through to ExAws
- blank bucket is unset, not a bucket named `""`
- uploads no longer sit inside a `Repo.stream` transaction
- `up(version: 1)` no longer emits V2 DDL
- `phx-blur` / form-less `phx-change` read `"value"`
- the cleanup hold-back gates on *runnable* (toggle + bucket), not the toggle alone

Phase 1 (`phase1.md`) approved pre-merge. This pass is the independent
read after merge.

## Issues Found

### 1. [BUG - HIGH] `object_path/1` was never used — FIXED

**File:** `lib/phoenix_kit/modules/emails/archiver.ex`

`6e7bc41` added `object_path/1` and a test for it, and the commit message
promised keys of the form `email-logs/2026/08/14/090703-ab12cd34.json`.
`archive_batch_to_s3/6` still built:

```elixir
s3_key = "#{prefix}#{DateTime.to_iso8601(now)}/batch-#{batch_id}.#{format}"
```

so every real upload would have been
`email-logs/2026-08-14T09:07:03Z/batch-….json` — colons in every object
name, which is exactly what the commit said it was removing. The helper
is `@doc false` public, so the compiler never warned it was unused, and
the test only called the helper.

**Fix:** `object_key/4` is the name that is uploaded; the test now asserts
the full key, not the unused half.

**Confidence:** 98/100

### 2. [BUG - MEDIUM] uniqueness expired after one hour — FIXED

**File:** `lib/phoenix_kit/modules/emails/archive_worker.ex`

```elixir
unique: [period: 3600, states: :incomplete]
```

The comment says a run that outlives its interval must not be joined by
the next tick. Oban uniqueness is checked against `inserted_at`, so a
backlog still `:executing` at T+3601s is no longer unique and the next
cron insert is accepted. Both jobs then select the same unstamped rows
and upload them twice. Every other worker in this package uses
`period: :infinity` for the same reason.

**Fix:** `unique: [period: :infinity, states: :incomplete]`. Completed and
discarded jobs are not `:incomplete`, so the following hour still
inserts. Locked in by `archive_worker_test.exs`.

**Confidence:** 93/100

### 3. [BUG - MEDIUM] `bucket: ""` still counted as a bucket — FIXED

**File:** `lib/phoenix_kit/modules/emails/archiver.ex`

The settings reader trims blanks to `nil`, but an explicit `:bucket` opt
went through `Keyword.get(opts, :bucket) || get_s3_bucket()` and then
`if bucket do`. Empty string is truthy, so `bucket: ""` (or whitespace)
skipped the fallback *and* passed the guard — upload against no name.
The worker never passes the opt, so this is a console/API path, not the
scheduled one.

**Fix:** the same trim-or-nil used for settings is applied to the opt
before the guard.

**Confidence:** 90/100

### 4. [NITPICK] `up/1` still said V1 is the only version — FIXED

**File:** `lib/phoenix_kit/modules/emails/migrations.ex`

The paragraph that explains why `:version` is honoured still claimed
"V1 is the only version today". The code now versions owned objects;
the doc matches.

**Confidence:** 100/100

## What Was Done Well

The four self-review defects (long transaction, pinned `:version`, blur
wiping the bucket, half-configured toggle disabling cleanup) are the
kind that gates never catch, and each landed with a test that fails
against the parent commit. `mark_archived/3` only stamps `archived_at IS
NULL`, so a retry cannot overwrite a key already written. Config gaps
(`:s3_not_configured`, `:no_bucket_configured`) return `:ok` from the
worker instead of burning attempts. The settings page says the schedule
lives in the host crontab rather than implying a job nobody configured.
Tests stop at the network boundary on purpose and pin the decisions that
actually broke.

## Left as-is

- **`s3_connections/0` lists only `aws_ses`.** Same note as Phase 1: that
  is the AWS integration type in this system. A future generic-AWS type
  would need the dropdown opened.
- **`get_s3_archived_size/0` is a 2 KB/row estimate.** Stated in the PR
  and in the code. A LIST on every settings render is the wrong trade.
- **Upload failure after `ExAws.request/2` is untested.** Needs an HTTP
  stub this package does not ship. Stop-on-failed-batch is visible in
  `archive_loop/8` and not worth a fake.
- **`delete_archived_logs/1` is two `delete_all`s, not a transaction.**
  Pre-existing; the FK is `ON DELETE CASCADE`, so deleting the logs
  alone would be enough. Not introduced here.
- **The archival scan (`archived_at IS NULL`) cannot use the V2 partial
  index (`WHERE archived_at IS NOT NULL`).** The index helps cleanup,
  not the job. The job's hot filter is `sent_at < cutoff`, which already
  has an index.

## Verdict

Approved with fixes — the feature is the right one, and the in-branch
self-review was unusually thorough. The unused `object_path` and the
one-hour unique window would have been the first two things a real
backlog run exposed.
