# PR #28 — Prove the webhook CSRF fix against a router that still has the bug

**Reviewed:** 2026-08-10 · **Author:** timujinne · **Verdict:** merged, no
changes required. Released in **0.2.0**.

+37 / −7 in one test file. Reviewed as part of the phoenix_kit 2.0 sweep.

## What it does, and why it is worth having

The existing regression test asserted only the "after" state: a cold POST to
`/phoenix_kit/webhooks/ses` with no session or CSRF token reaches the controller
and returns 200. That assertion passes for two very different reasons — the fix
works, or the route the test builds from `Routes.generate/1` never went through
`:browser` in the first place. It silently depended on `Routes.generate/1`
staying broken in a particular way to be meaningful.

The PR adds `BeforeFixRouter`, a fixture router that wires the webhook through a
`:browser` pipeline with `protect_from_forgery` — the exact shape the bug had —
and asserts a cold POST raises `Plug.CSRFProtection.InvalidCSRFTokenError`. Both
halves now share one `cold_conn/0` builder, so the two paths differ only in
which router handles the conn.

This is the right way to keep a "before" case permanently: it does not require
reverting the real fix, and it cannot rot into a tautology, because the bug
shape is pinned in the test file itself rather than inferred from production
code that has since changed.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0 |
| `mix test` | **1 doctest, 83 tests, 0 failures** (171 integration excluded — no Postgres available) |
