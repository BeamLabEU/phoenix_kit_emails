# Code Review: PR #18 — Add Brevo event polling: sender-aware Oban poller + settings UI

**Reviewed:** 2026-07-19
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/18
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** ede88a867e9ca34f3ccfcbbcbf0391657b4423f4
**Status:** Merged (8d970f8)

## Summary

Adds a Brevo transactional-email events poller (`BrevoClient`, `BrevoPollingJob`,
`BrevoPollingManager`, `BrevoIntegrations`, `BrevoEventNormalizer`), an on-demand
single-log sync path (`BrevoOnDemandSync`), a "Brevo Events" settings section, and
two correctness fixes: `Interceptor.update_after_send/2` now recovers Brevo's own
message id into `aws_message_id` (previously only `aws_ses` did this, so a Brevo
event could never be correlated back to its `Log`), and placeholder logs created
from an event now respect the event's own provider hint instead of always
labeling themselves `aws_ses`.

Architecturally this mirrors the existing `SQSPollingJob`/`SQSPollingManager`
self-scheduling-Oban-chain pattern closely, with two Brevo-specific twists: a
sender-aware gate (only polls integrations an *enabled* `brevo_api` `SendProfile`
actually points at) and a per-account opt-out list. `SQSProcessor.process_email_event/1`
is untouched — `BrevoEventNormalizer` translates Brevo's event vocabulary into the
same SES-shaped contract that function already expects.

## Issues Found

### 1. [BUG - MEDIUM] `Log.t()` referenced in a `@spec` but `Log` never defined `@type t` — FIXED

**File:** `lib/phoenix_kit/modules/emails/brevo_on_demand_sync.ex` line 43 (spec),
root cause in `lib/phoenix_kit/modules/emails/log.ex`

`BrevoOnDemandSync.sync/1`'s spec is `@spec sync(Log.t()) :: ...`, but
`PhoenixKit.Modules.Emails.Log` is an `Ecto.Schema` module that never declared
`@type t`. This is the only `Log.t()` reference in the whole codebase, so nothing
surfaced it until dialyzer actually ran:

```
lib/phoenix_kit/modules/emails/brevo_on_demand_sync.ex:43:17:unknown_type
Unknown type: PhoenixKit.Modules.Emails.Log.t/0.
Total errors: 1
```

`mix dialyzer` is part of this repo's `mix precommit`/`mix quality` gates per
AGENTS.md, but the PR's own "Verification" section only lists `mix test`,
`mix credo --strict`, and a host-app compile with `--warnings-as-errors` — dialyzer
was never run before merge, so this slipped through.

**Fix applied:** added the standard Ecto-schema typespec to `log.ex`:

```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true}

@type t :: %__MODULE__{}

schema "phoenix_kit_email_logs" do
```

`mix dialyzer` is clean after this change (0 errors, re-verified).

**Confidence:** 95/100

### 2. [NITPICK] Misconfig backoff's moduledoc promise ("missing/invalid credentials") doesn't fully match the implementation

**File:** `lib/phoenix_kit/modules/emails/brevo_polling_job.ex` lines ~479-491 (moduledoc) vs. `poll_integration/1` (line 625) and `fetch_page/4` (line 650)

`poll_integration/1` only returns `:misconfigured` when `BrevoIntegrations.resolve_api_key/1`
fails (missing/empty `api_key` in the integration's stored credentials). A key that
*is* present but has been revoked/rotated on Brevo's side surfaces as
`BrevoClient.fetch_events/3` returning `{:error, :invalid_credentials}` (a 401)
inside `fetch_page/4` — but `poll_integration/1` discards `fetch_page/4`'s return
value and unconditionally returns `:ok`. So a revoked key keeps polling at the
normal interval (logging an error every cycle) instead of triggering the
`@misconfig_backoff_ms` back-off the moduledoc describes as covering "missing/invalid
credentials."

Not fixed — this exactly mirrors `SQSPollingJob`'s own existing behavior
(`validate_configuration/1` there only checks *config shape*, not whether AWS
actually accepts the credentials at request time; a bad AWS key similarly polls at
the full interval forever), so it's consistent with established precedent in this
codebase rather than a regression this PR introduced. Worth a follow-up if the team
ever tightens SQS's equivalent behavior, but out of scope here.

**Confidence:** 70/100

### 3. [OBSERVATION] Brevo-sourced placeholder logs get `to: "unknown@example.com"` instead of the real recipient

**File:** `lib/phoenix_kit/modules/emails/brevo_event_normalizer.ex` (`normalize/1`'s `mail` map) and `sqs_processor.ex`'s `create_placeholder_log_from_event/2`

`BrevoEventNormalizer.normalize/1` builds `"mail" => %{"messageId" => ..., "provider" => "brevo_api"}` — it never carries `brevo_event["email"]` through. For an SES/SNS event, `mail.destination` is what `create_placeholder_log_from_event/2` reads to populate a placeholder log's `to` field; Brevo events have no equivalent, so an unmatched Brevo event's placeholder always gets `to: "unknown@example.com"`.

This only matters in the already-anomalous case where a Brevo event arrives with no
matching `Log` row (correlation miss) *and* `email_create_placeholder_logs` is
enabled — the PR's own placeholder test only asserts the `provider` field, not
`to`. Not fixed: low severity, edge-case-on-an-edge-case, and outside what the PR
set out to do. Flagging so it's on record for whoever next touches
`BrevoEventNormalizer`.

**Confidence:** 80/100

## What Was Done Well

- Excellent moduledocs throughout — every design decision (sender-aware gate,
  shared-interval backoff instead of per-integration, page cap, "days" fetches
  for on-demand sync vs. date-range for the poller, `forced: true` bypass
  semantics) is explained with its rationale inline, not just what the code does.
- `SQSProcessor.process_email_event/1`'s contract was made explicit rather than
  quietly relied upon — the moduledoc addition documents it as stable/public
  before building `BrevoEventNormalizer` against it.
- Real correctness fixes bundled in cleanly: the `aws_message_id` correlation gap
  for Brevo sends, and the placeholder-provider mislabeling, both land in this PR
  with dedicated regression tests (`InterceptorBrevoTest`, the placeholder test in
  `BrevoEventsIntegrationTest`).
- Strong test coverage: every Brevo event type has a normalizer test, the poller
  has dedicated tests for the sender-aware gate, idempotency, pagination, and
  misconfiguration (the "no api_key" case), and both UI sync entry points
  (Details page, emails list row) have their own tests. All HTTP is stubbed via
  `Req.Test` — no real network calls in tests.
- Consistent architecture: reuses `SQSPollingJob`'s self-scheduling chain, unique
  dedup window, and delete-then-reinsert scheduling pattern rather than inventing
  a new mechanism for a second provider.
- Honest edge-case handling in `BrevoOnDemandSync`: explicit user-facing error
  strings for "no recoverable message id yet" and "no active integration," with
  the correct bypass semantics (skips `brevo_events_enabled` and the per-account
  opt-out — a manual request outranks the background poller's throttles — but
  still respects `Emails.enabled?/0`).

## Validation

- `mix format --check-formatted` — clean
- `mix compile --warnings-as-errors` — clean
- `mix credo --strict` — clean (1123 mods/funs, no issues)
- `mix dialyzer` — 1 error before this review's fix (Issue #1), clean after
- `mix test` — 35 non-DB tests pass; the remaining 59 DB-backed tests (the bulk of
  this PR's own suite) could not be executed in this review environment — no local
  Postgres instance was available. Not a PR defect; flagging so the gap is on
  record rather than silently assumed green.

## Verdict

**Approved with fixes.** One real gate regression (dialyzer) found and fixed
in this review. The two remaining findings are a documentation/implementation
mismatch that matches existing SQS precedent, and a minor data-completeness gap
in an already-rare edge case — neither blocks merge (which already happened) and
neither warrants a follow-up commit on its own. The feature itself is well-designed,
consistently mirrors the existing SQS polling architecture, and is thoroughly
tested for everything that could be tested without a live Postgres instance.
