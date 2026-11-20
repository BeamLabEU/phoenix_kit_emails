# Post-0.10.0 code review — findings and fixes

**Reviewer:** Mistral Vibe (Claude Opus 5.5)
**Date:** 2026-11-20
**Base:** `f78d844` (last Hex release 0.10.0 was tagged at `a3b67fd`; the two commits
after it — `491882e` docs gate, `f78d844` lockfile bump — touch only `mix.exs`,
`mix.lock`, `AGENTS.md`, no `lib/` code)
**Landed in:** `6f06570` "Fix post-0.10.0 review findings across send, event,
webhook and export paths"

## Scope and method

Full review of `lib/` (~30k lines, 59 files) plus `test/`. The automated gate was
already green at the base (compile `--warnings-as-errors`, 901 tests + 12
doctests, `credo --strict`, `format --check-formatted`, dialyzer, docs), so the
goal was real defects, not style. Four read-only review passes ran in parallel
over disjoint slices (outgoing-send core; inbound event/SQS/Brevo/webhook; web
layer; data/maintenance), each returning file:line findings. **Every HIGH/MEDIUM
finding was re-verified against the source before fixing** — several cited line
numbers were stale, and two findings were wrong (the `pk_link navigate=...` links
in `amazon_ses_sqs.html.heex` are fine because core's `pk_link` prefixes paths
itself; left untouched). Findings were fixed centrally to keep one coherent
diff; 19 regression tests were added.

Severity scale: `BUG - CRITICAL` / `BUG - HIGH` / `BUG - MEDIUM` / `NITPICK` /
`OBSERVATION`. All items below are FIXED in `6f06570` unless marked otherwise.

## Findings

### 1. [BUG - CRITICAL] Export was broken end to end — FIXED

**Files:** `web/routes.ex`, `web/export_controller.ex`, `web/emails.ex`,
`web/details.html.heex`, `paths.ex`

`routes.ex` registered `get("/emails/export/:format", ExportController, :export)`
but the controller defines only `export_logs/2`, `export_metrics/2`,
`export_blocklist/2`, `export_email_details/2` — no `export/2` — so every request
to the mounted route raised `UndefinedFunctionError` (500). Separately the admin
"Export CSV" buttons linked to `/admin/emails/export` and
`/admin/emails/:uuid/export`, paths no route matches (404). No test covered any
of this.

Fix: routes now register the four real actions with `:format`
(`/emails/export/logs|metrics|blocklist/:format`, `/emails/export/email/:id/:format`);
each action serves `csv` and `json` (anything else is a 400, not a silent CSV);
links go through new `Paths.export_logs/1` / `export_metrics/1` /
`export_blocklist/1` / `export_email/2` helpers built with `locale: :none` so they
match the root-scoped mount core uses for module public routes (a bare
`Routes.path/1` would prepend a locale segment no route matches); the logs export
passes an explicit high limit instead of the list's 50-row default; the blocklist
export returns the real `RateLimiter.list_blocklist/1` instead of an empty stub;
and a `plug :require_emails_module` adds the per-module permission +
enabled-module check the admin LiveViews get from core's live_session hook (the
route previously checked only the admin role).

### 2. [BUG - HIGH] SQS poison-message loop on `DeliveryDelay` / `Rendering Failure` — FIXED

**File:** `sqs_processor.ex` (`determine_event_type/1`), `event.ex`

`determine_event_type/1` did only `String.downcase/1`, so AWS's real capitalized
`"DeliveryDelay"` → `"deliverydelay"` and `"Rendering Failure"` → `"rendering
failure"` (with a space) never matched the `"delivery_delay"` /
`"rendering_failure"` dispatch clauses. They fell to `unknown_type` →
`{:error, {:unknown_event_type, _}}` → the SQS message was never deleted and was
redelivered forever, and the event was never recorded. The webhook path already
normalized correctly via a private `Event.normalize_event_type/1`. A non-binary
`eventType` (e.g. `123`) raised `ArgumentError` inside `String.downcase/1`, same
loop.

Fix: `Event.normalize_event_type/1` is now public and used by both paths (lowercase,
space→underscore, `"deliverydelay"`→`"delivery_delay"`, non-binary→`"unknown"`).

### 3. [BUG - HIGH] Before-send interceptor could abort the actual send — FIXED

**File:** `interceptor.ex` (`do_intercept_before_send/2`)

Core calls `provider.intercept_before_send/2` at `PhoenixKit.Mailer` with no
rescue. The before-send logging path had none either (the after-send path did), so
a raise inside `create_email_log`/`enrich_send_opts` (DB blip after `enabled?/0`
answered from cache, a settings read failing) propagated into `deliver_email/2`
and the message was never sent — contradicting the documented "a logging problem
can never break a send" invariant. Fix: `rescue` logs the error + stacktrace and
returns the email untouched.

### 4. [BUG - HIGH] Archiver re-runs destroyed already-compressed bodies — FIXED

**File:** `archiver.ex` (`build_compression_query/2`, `compress_email_body/1`)

The compression query selected every old row with a non-empty `body_full` but
did not exclude rows already compressed (detected elsewhere via
`body_full LIKE 'H4sI%'`). On a second run, gzip-of-base64 doesn't shrink
(ratio ~1.0), so the "not worth it" branch ran `body_full: nil` — the compressed
archive was deleted and the preview became 500 chars of base64. Fix: the query
excludes `H4sI%` rows and the compressor also skips them (defense in depth).

### 5. [BUG - MEDIUM] Sampling applied twice (effective rate = rate²) — FIXED

**Files:** `emails.ex` (`create_log/1`, private `should_log_email?/1`),
`interceptor.ex`

The interceptor gates on a deterministic per-recipient `phash2` at
`email_sampling_rate`; `Emails.create_log/1` then rolled its own
`:rand.uniform(100) <= rate`, so the effective rate was rate² and non-deterministic
(same recipient logged on one send, dropped on another), and it could drop the
system/error mails the interceptor explicitly guarantees. The SQS placeholder
path deliberately bypasses `Emails.create_log` (uses `Log.create_log` directly)
precisely to avoid this roll. Fix: the roll now lives only in the interceptor;
`create_log` keeps just the `enabled?/0` gate.

### 6. [BUG - MEDIUM] `email_save_headers` ignored on outgoing mail — FIXED

**File:** `interceptor.ex` (`extract_headers/2`)

The setting was only read on the inbound path (`sqs_processor.ex`). Outgoing logs
stored the full header map regardless. Fix: `extract_headers/2` stores `%{}` when
`Emails.save_headers_enabled?()` is false.

### 7. [BUG - MEDIUM] Duplicate at-least-once delivery downgraded the log — FIXED

**File:** `interceptor.ex` (`update_after_send/2`)

`status: "sent"` was set unconditionally, so a retried queue job that re-succeeded
after a SES `delivery`/`open` event reset the row from `delivered`/`opened` back to
`sent` (and wrote a duplicate `send` event). Fix: only transition to `"sent"` from
a pre-delivery status; post-delivery statuses (`delivered/opened/clicked/bounced/
complaint/rejected/delayed`) are left alone.

### 8. [BUG - MEDIUM] Webhook 500s on malformed payloads — FIXED

**Files:** `web/webhook_controller.ex`, `event.ex`, `emails.ex`

- `JSON.decode(Message)` returning a list/scalar was passed to
  `process_webhook_event/1` (only an `is_map` clause) → `FunctionClauseError`;
  the logging clauses did `event_data["eventType"]` on a list (`KeyError`) and
  `get_in(...) |> List.first()` on a binary. Fix: decode result is matched
  `when is_map`, else `{:error, :invalid_message}` (400); logging uses safe
  `mail_keys/1` / `first_recipient/1` helpers.
- `webhook_data["mail"]["messageId"]` and `webhook_data["delivery"]["timestamp"]`
  raised when the section was a list/scalar. Fix: `get_in` everywhere (in
  `emails.ex` `extract_message_id/1`, `event.ex` `parse_timestamp/1`, and a new
  `map_section/2` for the bounce/complaint/click/open sections).
- Non-binary `Timestamp` (`"Timestamp": 123`) raised inside
  `DateTime.from_iso8601/1`. Fix: `is_binary` guard at `verify_request_age/1`.
- A far-future `Timestamp` gave a negative `age_seconds` which `<= 300` accepted,
  defeating the replay window when signature verification is off. Fix: symmetric
  `abs(age_seconds) <= 300` (tolerates sub-second clock skew that reads as -1s —
  caught by a regression test — while rejecting absurd future/past).

### 9. [BUG - MEDIUM] Webhook source-IP check rejected legitimate AWS traffic — FIXED

**File:** `web/webhook_controller.ex` (`verify_aws_ip/1`, `@aws_sns_ip_ranges`)

`webhook_check_aws_ip` defaults on, and the bundled `@aws_sns_ip_ranges` is a
stale IPv4-only subset of AWS's published ranges; the IPv4-only CIDR matcher made
every IPv6 peer fall through to `false`, so legitimate SNS notifications (all
IPv6, and most IPv4 regions) were 403'd before signature verification. Fix: when
SNS signature verification is on (the default, and the cryptographic proof of
origin), a non-matching IP is a warning, not a block; when signature verification
is off, the IP list stays a hard gate (it is then the only check). **This is a
behavior change / judgment call — see Open questions.**

### 10. [BUG - MEDIUM] Placeholder logs bypassed `email_create_placeholder_logs` — FIXED

**File:** `sqs_processor.ex`

`delivery_delay` and `subscription` called `create_placeholder_log_from_event/2`
directly, creating placeholder logs even with the setting off (default). Fix: all
paths go through one `create_placeholder_if_enabled/4` helper gated on
`Emails.placeholder_logs_enabled?()`.

### 11. [BUG - MEDIUM] Rate limiter: nil crash + case-sensitive key — FIXED

**File:** `rate_limiter.ex`

`check_limits(%{to: nil})` → `l.to == ^nil` raised `ArgumentError`; a list-valued
`to` failed to cast. Fix: `check_recipient_limit/2` / `check_sender_limit/2` have
`is_binary` guards + a `:ok` fallback. The counters compared `l.to == ^email`
case-sensitively while the blocklist downcases, so `User@x.com` vs `user@x.com`
got separate counters and the per-recipient limit was bypassable by case
rotation. Fix: `fragment("lower(?)", l.to) == ^String.downcase(email)` (same for
`from`, incl. `high_frequency_sender?/1`). `get_time_window/1` got a fallback
clause instead of `CaseClauseError`.

### 12. [BUG - MEDIUM] Unknown analytics period crashed public APIs — FIXED

**Files:** `metrics.ex` (`get_time_range/1`), `log.ex` (`get_period_dates/1`)

Both were `case` with no catch-all; `Metrics.get_dashboard_data(:bogus)` /
`Log.get_engagement_metrics(:bogus)` raised `CaseClauseError`. Fix: fallback to
`:last_7_days` / `:last_30_days`.

### 13. [BUG - MEDIUM] Dashboard `Task.await_many` crash propagation — FIXED

**File:** `metrics.ex` (`get_dashboard_data/1`)

Six `Task.async` queries; one raise exited the caller opaquely via `await_many`.
Fix: each query runs inside a `safe/2` helper (rescue + catch, logged) returning a
type-appropriate empty default.

### 14. [BUG - MEDIUM] Template export path traversal — FIXED

**File:** `template_export.ex` (`files_for/2`)

`part_files/6` built `Path.join([out, template.name, ...])` from the raw legacy DB
`name`; a name with `/`, `\`, or `..` wrote outside `--out` (and `--force`
overwrote anywhere). Fix: `validate_name!/1` refuses names not matching
`~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/`.

### 15. [BUG - MEDIUM] Manual SQS sync deleted unparseable messages — FIXED

**File:** `emails.ex` (`process_sqs_batch/2`)

A matching message that failed `parse_sns_message/1` was added to the delete list
→ the SES event was permanently lost. Fix: unparseable matches are left in the
queue (visibility timeout returns them to the poller).

### 16. [BUG - MEDIUM] Details "Sync Status" crashed on a log with no message id — FIXED

**File:** `web/details.ex`

A queued/unsent log has neither `aws_message_id` nor `message_id`; `sync_email_status(nil)`
has only a `when is_binary` clause → `FunctionClauseError` killed the LiveView.
Fix: guard flashes an error and returns.

### 17. [BUG - MEDIUM] Blocklist CSV import: crash + mislabeled errors — FIXED

**File:** `web/blocklist.ex`

The only `handle_event("import_csv", ...)` clause matched `%{"csv_content" => _}`;
a crafted event without a binary value → `FunctionClauseError`. The `rescue _`
also swallowed DB errors from `RateLimiter.add_to_blocklist/3` as "Invalid CSV
format". Fix: `is_binary` guard + fallback clause; rescue logs the real error.

### 18. [NITPICK] Blocklisted queued recipient closed as `failed`, not `rejected` — FIXED

**File:** `send_job.ex` — `{:cancel, :recipient_blocked}` now calls a `reject_log/2`
using `Log.mark_as_rejected/3` so analytics don't count a permanent block as a
retryable failure.

### 19. [NITPICK] `critical_email?/1` KeyError on `%EmailLogData{}` — FIXED

**File:** `archiver.ex` — used `email_attrs[:status]` (Access); the struct has no
`:status` key → `KeyError`. Now `Map.get/2`.

### 20. [NITPICK] Retention cleanup crashed on 0/non-integer days — FIXED

**File:** `log.ex` (`cleanup_old_logs/2`) — clamps 0/negative to the 1-day floor,
no-ops on non-integers, keeping the `{count, nil}` shape.

### 21. [NITPICK] Newsletters `update_delivery_status` unguarded — FIXED

**File:** `sqs_processor.ex` (`apply_delivery_event/4`) — added the
`function_exported?(..., :update_delivery_status, 3)` guard the sibling
`increment_broadcast_counter` already had.

### 22. [NITPICK] Brevo aggregate `bounces` recorded as hard — FIXED

**File:** `sqs_processor.ex` (`normalize_bounce_type/1`) — `nil` bounceType now
maps to `"soft"` (blocklisting keys off `determine_bounce_status/1`, so this only
labels the Event row correctly).

### 23. [NITPICK] Hardcoded settings URL in an error string — FIXED

**File:** `emails.ex` — the AWS-credentials error interpolated
`Paths.settings()/0` instead of a literal `/admin/settings/email-sending`.

### 24. [NITPICK] Test-tracking email HTML-escaped the recipient — FIXED

**File:** `provider.ex` — `recipient_email` is operator-supplied and landed in an
HTML body unescaped; now `escape_html/1`.

### 25. [OBSERVATION] Dead `reset_rate_limits` handler — FIXED (removed)

**File:** `web/queue.ex` — no button wired to it; it flashed "Rate limits reset"
while doing nothing. Removed (the counters are derived from log rows and not
separately resettable).

### 26. [OBSERVATION] Bare `rescue _ ->` hid real failures — FIXED

**Files:** `status.ex` (`job_counts`/`today_counts`), `event_tracker.ex`,
`sqs_polling_manager.ex`, `brevo_polling_manager.ex`,
`web/settings_sections/email_tracking.ex` (`s3_connections`) — all now log the
rescued error before returning the zeroed/empty fallback, so a DB outage is
distinguishable from "no jobs / not running".

### 27. [OBSERVATION] Boot reconcile ran in a bare anonymous `Task` — FIXED

**File:** `supervisor.ex` — now a named `:temporary` child (a map child_spec
defaults to `:permanent`, which would loop on normal completion) with a fully
`rescue`/`catch`-guarded body that logs. Correctness is backstopped by the
`EventTrackerReconcileWorker` cron, so a missed boot reconcile self-heals.

## What was done well (kept as-is)

- `queue.ex`/`send_job.ex` decision logic and the `rescue`+`catch` fall-through-to-
  inline in `enqueue/2` — correct and well-guarded; `serialize/1`'s documented
  allowlist is the right call for job args.
- `provider.ex` after-send rescue + nil-safe header lookup; `@behaviour` on the
  provider so core contract drift fails at compile time.
- All `fragment(...)` SQL uses parameterized `?` — no injection.
- Web `Routes.path/1` usage is prefix-safe everywhere; LiveView param handling is
  hardened (whitelisted sort fields, `parse_int`/`parse_page` guards, no
  `String.to_atom` on user input); no `raw`/`{:safe}` HTML in templates.
- Migrations: idempotent, `down/1` never drops, PG-regex lookbehind verified on PG
  18.4; archive worker `unique:` correctly prevents overlapping ticks.
- Webhook SNS signature verification and SSRF URL validation are genuinely solid.

## Verification

- 19 new regression tests: `test/phoenix_kit/modules/emails/code_review_pure_test.exs`
  (event-type normalization, Paths export helpers, export actions exist,
  template-name traversal refusal) and `code_review_integration_test.exs`
  (SQS dispatches DeliveryDelay/Rendering Failure, webhook 400s on malformed
  payloads/bad timestamps, export routes don't 500, rate limiter nil +
  case-insensitive, metrics unknown period).
- Full gate green at `6f06570`: `compile --warnings-as-errors`, **920 tests + 12
  doctests, 0 failures**, `credo --strict` (no issues), `format --check-formatted`,
  dialyzer (passed; 2 pre-existing skips in `.dialyzer_ignore.exs`),
  `docs --warnings-as-errors`, `hex.audit`, `deps.unlock --check-unused`.
- One regression was caught and fixed during the work: the future-timestamp guard
  (`age >= 0`) rejected fresh requests due to sub-second clock skew (age reads as
  -1s) — caught by `webhook_route_csrf_test.exs`, fixed to a symmetric window.

## Open questions / judgment calls

- **Webhook IP check demoted to warn-only when signature verification is on**
  (finding 9). The alternative is maintaining a fetched copy of AWS's
  `ip-ranges.json`; the bundled list is inherently stale. If a strict allowlist is
  preferred, that's the change to make — flag if so.
- **Sampling now lives only in the interceptor** (finding 5). Any future direct
  caller of `Emails.create_log/1` for outgoing mail bypasses sampling; the
  function's doc says so. Inbound placeholder logs intentionally never sample.
- The manual "sync status" SQS path still deletes successfully-parsed matching
  messages during the poll (before the caller processes the returned events).
  Left as-is: the event data is captured, this is a diagnostic admin path, and the
  primary `SQSPollingJob` pipeline handles deletion correctly. Worth revisiting
  only if that path is ever used for more than diagnostics.
