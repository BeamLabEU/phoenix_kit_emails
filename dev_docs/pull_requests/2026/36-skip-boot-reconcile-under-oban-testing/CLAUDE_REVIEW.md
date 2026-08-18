# Code Review: PR #36 — Skip the boot reconcile while Oban is in a testing mode

**Reviewed:** 2026-08-18
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/36
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** f4d1e82b803002a3b1f695ce4d40b3b766c36560
**Status:** Merged

## Summary

`Supervisor.start_polling_when_oban_ready/0` spawns a `Task` at boot that calls
`EventTrackerReconciler.reconcile/0`, which in turn calls `Oban.cancel_all_jobs/1`
(a DB write) to converge each tracker's chain. That `Task` owns no Ecto sandbox
connection, so under a host's test suite (`Oban.Config.testing` set to `:manual`
or `:inline`) the write can only fail — and it fails loudly, dumping a
`DBConnection.OwnershipError` into every test run of every host that installs
this module.

The PR gates the reconcile behind a new `reconcile_on_boot?/1` predicate that
only allows it when Oban is *not* in a testing mode
(`%Oban.Config{testing: :disabled}`). `wait_for_oban/2` is changed to hand back
the resolved `%Oban.Config{}` (`{:ok, config}` instead of bare `:ok`) so the
caller has something to gate on. A new unit test
(`test/boot_reconcile_gate_test.exs`) exercises the predicate directly against
`:disabled`, `:manual`, and `:inline`.

## Verification

- Confirmed `EventTrackerReconciler.reconcile/1` does call
  `Oban.cancel_all_jobs/1` (`lib/phoenix_kit/modules/emails/event_tracker_reconciler.ex:153`),
  backing the stated rationale.
- Confirmed Oban's own `testing` field is exactly the three-value enum used here
  (`:disabled | :inline | :manual`, `deps/oban/lib/oban/config.ex:29`), so the
  gate's pattern match is exhaustive and the test's coverage of all three modes
  is complete — no fourth mode to miss.
- `wait_for_oban/2`'s `catch` clause is unaffected; only the success path's
  return shape changed, and its sole caller (`start_polling_when_oban_ready/0`)
  was updated in the same diff.
- `mix precommit` (format + credo --strict + dialyzer) and `mix test` (462
  tests, 1 doctest) both pass clean on the current tree.

## Issues Found

None. The fix is narrowly scoped, the rationale is verified against the code it
describes, and the new test actually exercises the boundary it claims to
(all three `testing` values, not just the changed one).

## What Was Done Well

- Root-caused the actual failure (unowned DB connection from a bare `Task`)
  rather than papering over the symptom (e.g. wrapping the reconcile in a
  `try/rescue`).
- Kept the predicate a plain function on `%Oban.Config{}` with `@doc false` +
  a comment explaining *why*, consistent with the existing `should_start_*?`
  gate pattern in the same module.
- Test asserts the gate for every `testing` value Oban defines, not just the
  one the PR title mentions.

## Verdict

Approved — no changes required.
