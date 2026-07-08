# Code Review: PR #14 — Fix: don't request savepoint mode outside an open transaction

**Reviewed:** 2026-07-08
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/14
**Author:** timujeen (timujinne)
**Head SHA:** 7da80bb638713d4b4c06ac6e98417a5d6131af72
**Status:** Merged

## Summary

`Event.create_event/1` was changed in 0.1.8 to always insert with `mode: :savepoint`.
The intent was correct: `Log.mark_as_opened/2` and `mark_as_clicked/3` run
`create_event/1` inside a `repo().transaction`, and without a savepoint a
unique-constraint violation on the dedup index aborts the *whole* Postgres
transaction — silently rolling back the caller's preceding status update at commit,
even though `create_event/1` translates the violation to `{:ok, :duplicate_event}`.

The bug: `mode: :savepoint` is **not** a no-op outside a transaction. Postgres
savepoints can only exist inside a transaction, so DBConnection raises
`DBConnection.TransactionError` ("transaction is not started") when no enclosing
transaction is open. Every SQS-processor path creates events from a plain
`Task.async` with no transaction, so those inserts were crashing and the
`phoenix_kit_email_events` audit trail stopped populating for SES events routed
through SQS.

The fix requests `mode: :savepoint` only when `repo().in_transaction?()` is true:

```elixir
insert_opts = if repo().in_transaction?(), do: [mode: :savepoint], else: []
case repo().insert(changeset, insert_opts) do
```

## Verification

Every claim in the PR was checked against the code, not just the description:

- **`mode: :savepoint` raises outside a transaction — CONFIRMED.**
  `db_connection` 2.10.2 (`deps/db_connection/lib/db_connection.ex:105`) builds the
  `%DBConnection.TransactionError{status: :idle, message: "transaction is not
  started"}` when a savepoint-mode op runs with an idle connection. Ecto 3.14 /
  Postgrex 0.22 are in the tree.
- **Transactional callers really are transactional — CONFIRMED, and broader than
  the PR text says.** `create_event/1` runs inside `repo().transaction` in *four*
  `Log` functions, not two: `mark_as_bounced/3`, `mark_as_opened/2`,
  `mark_as_clicked/3`, and `mark_as_failed/3` (`log.ex:570/612/646/736`). Gating on
  `in_transaction?/0` (rather than special-casing the two named callers) correctly
  protects all four — a strictly better choice than the comment implies.
- **SQS paths have no transaction — CONFIRMED.** `sqs_processor.ex` contains no
  `repo().transaction`; SES events are processed from `Task.async` in
  `sqs_polling_job.ex:313`. `Log.update_log/2` (its own implicit tx) then a separate
  `create_event/1` — no ambient transaction, so `in_transaction?/0` is `false`.
- **Why tests never caught it — CONFIRMED root cause.** `Ecto.Adapters.SQL.Sandbox`
  wraps every checked-out test in a transaction and itself uses `mode: :savepoint`
  (`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:361`). Under the sandbox,
  `in_transaction?/0` is *always* true, so the non-transactional path — the one that
  crashed in production — is unreachable in a sandboxed test. This library also has
  no standalone DB test harness (`test_helper.exs` only starts ExUnit; the Repo comes
  from the parent app via `RepoHelper`), so a regression test is not practical here.

## Issues Found

### 1. [OBSERVATION] Changelog/commit narrative undercounts the affected SQS paths

**File:** `CHANGELOG.md` (0.1.9 entry), commit message
The narrative names the affected non-transactional paths as "(delivery, bounce,
complaint)". The SQS **open** and **click** paths
(`sqs_processor.ex:1146` `create_open_event/3`, `:1170` `create_click_event/3`) also
call `Emails.create_event/1` directly, outside any transaction, and were equally
affected pre-fix. Purely a documentation-accuracy nit — the `in_transaction?/0`
fix covers open/click too. Left as-is; not worth an amended history.
**Confidence:** 95/100

### 2. [OBSERVATION — pre-existing, out of scope] `mark_as_failed/3` emits an event type the changeset rejects

**File:** `log.ex:746`, `event.ex:120`
`Log.mark_as_failed/3` builds an event with `event_type: "failed"`, but `"failed"`
is not in `changeset/2`'s `validate_inclusion` whitelist
(`queued|send|delivery|bounce|complaint|open|click|reject|delivery_delay|subscription|rendering_failure`).
`create_event/1` therefore returns `{:error, changeset}` (a validation error, never
reaching the DB), and because the return value is ignored inside the
`repo().transaction` block, the transaction still commits with the status update —
so the "failed" event row is silently never written. This predates PR #14 (nothing
to do with savepoints) and is **not** fixed here to keep the release scoped. Worth a
follow-up: either add `"failed"` to the whitelist or drop the dead `create_event`
call in `mark_as_failed/3`.
**Confidence:** 90/100

### 3. [OBSERVATION — release gate, upstream/pre-existing] `mix hex.audit` fails on hackney CVEs

**File:** `mix.lock` (transitive), release gate
`mix precommit` fails at its `cmd mix hex.audit` step: **hackney 1.25.0** carries four
2026 advisories (CVE-2026-47069 / 47071 / 47075 / 47076 — CR/LF injection, SSRF
allowlist bypass, SOCKS5 TLS timeout). hackney enters the tree via `ex_aws`, whose
`hackney ~> 1.16` constraint pins it to the 1.x line. **1.25.0 is the newest 1.x
release** — the fixes exist only in hackney 4.x, which the `~> 1.16` requirement
forbids — so there is no in-tree remediation without `ex_aws` relaxing its pin
(upstream). This is pre-existing (0.1.8 shipped hackney 1.x too) and unrelated to
this PR. The release proceeded on the code-quality gate (`mix quality.ci`:
format-check + credo --strict + dialyzer, all green); the failing `hex.audit` step
was skipped as a known-broken upstream advisory check, not a defect in this repo's
code. Follow-up for the maintainer: track `ex_aws` for a hackney-4.x-capable release,
or pin the ex_aws HTTP client to `finch` (already a dependency) and drop hackney.
**Confidence:** 92/100

## What Was Done Well

- **Root-caused, not guessed.** The comment and commit message explain *why*
  savepoint mode is needed inside a transaction (scopes the constraint rollback) and
  *why* it must be conditional outside one — the reasoning matches DBConnection's
  actual behavior.
- **`in_transaction?/0` over caller-name special-casing.** The gate is decided by the
  runtime transaction state, which automatically covers all four transactional
  callers and any future ones, and is a no-op-cost check.
- **No regression risk.** Inside a transaction, behavior is identical to 0.1.8
  (`mode: :savepoint`); outside, it goes from *crash* to *works*. Strictly an
  improvement.
- **Excellent inline documentation** of the savepoint semantics and the SQS
  non-transactional path, so the next reader won't "simplify" it back.

## Verdict

**Approved.** The fix is correct, minimal, and well-reasoned; every claim verified
against the source. No code changes required. Two documentation-level observations
recorded above (one cosmetic, one a pre-existing out-of-scope follow-up).
