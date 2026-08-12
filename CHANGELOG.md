# Changelog

## 0.3.0 - 2026-08-12

### Upgrading — read this first

This release adds a column to `phoenix_kit_email_logs`, and the schema in the
code expects it. **Migrate before you restart**, not after:

```
mix phoenix_kit.update --yes   # applies the module chain (Emails V01)
# ...then restart the application
```

Restarting first leaves the running code selecting a column the database does
not have, and every query against `phoenix_kit_email_logs` fails until the
update lands. Both steps are idempotent, so a host that has already run them is
unaffected.

Run `mix phoenix_kit.doctor` first. V01 adopts the module's six tables, which
means it is the first thing to replay their constraints on a long-lived
database, and doctor reports the two conditions that make that interesting: a
drifted `phoenix_kit_email_events` shape and orphaned `email_log_uuid` rows.

The migration bounds itself with `SET LOCAL lock_timeout = '5s'`, so behind a
long-running reader it fails fast with a clear error instead of hanging the
deploy — retry during a quiet window. It also takes a brief write lock on
`phoenix_kit_email_logs` while building the new index; see
`PhoenixKit.Modules.Emails.Migrations`' "Locking" section if that table is
large.

### Added

- **Multi-account AWS SES delivery event tracking.** SQS polling could only ever
  reach one AWS account: the queue URL was a single setting, the credentials
  cache had a single key, and the Oban chain is unique per worker. With two SES
  connections configured, one account's events were never collected — and the
  poller could be handed account A's queue with account B's keys.

  One Oban chain still, with N accounts polled inside each cycle (the shape
  `BrevoPollingJob` already used). Each account carries its own queue, DLQ,
  topic, configuration set and region under an `aws_tracking:<integration_uuid>`
  setting, its own credentials, and its own opt-out. The "Amazon SES & SQS"
  settings section grows a row per account, each with its own "Setup
  Infrastructure" button that creates the resources in *that* account.

- **Per-account SES configuration sets.** SES publishes delivery, bounce and
  complaint events only through a configuration set that exists in the SENDING
  account, so a single global name is silence for every account but one. The
  name now travels with the account. While the sending account can only be
  inferred (see below), the global name is still used for safety: a
  configuration set that does not exist in the sending account is a failed
  send, not just a lost event.

- **`phoenix_kit_email_logs.integration_uuid`** — which account sent a message,
  not just which provider kind. Nullable, best-effort, and backed by the SES
  event's own `mail.sendingAccountId`, which is now kept in the stored
  `event_data` alongside `sourceArn` and `configurationSet` as verifiable
  provenance.

- **A module-owned migration chain** (`PhoenixKit.Modules.Emails.Migrations`).
  V01 adopts the six tables nothing outside this package uses, alongside core's
  baseline, which still creates them — a deliberate transitional duplication.
  See `dev_docs/reports/2026-08-12-emails-table-adoption.md`.

### Known limitation

Core does not yet pass the sending integration's uuid to the tracking
interceptor, so for a send routed explicitly through a non-default connection of
the same provider kind, `integration_uuid` is inferred and can name the default
account instead. The column is an index, not a source of truth; the SES event's
`mail.sendingAccountId` is. Per-account configuration sets are deliberately
withheld in exactly that ambiguous case.

## 0.2.1 - 2026-08-11

### Fixed

- **Twenty-four Estonian and Russian entries carried the translation of "Poll
  now"** (#31) — among them "AWS Region", "Date", "Module" and "Legacy", so
  unrelated parts of the UI all read "Alusta pollimist" / the Russian
  equivalent. The files passed every usual check (no empty `msgstr`, no `fuzzy`
  flags), which is why this survived: it is only visible when msgids are grouped
  by identical `msgstr`.

  The PO **header** was hit too. `msgid ""` had been given
  `msgstr "Alusta pollimist"`, which concatenates onto the metadata block — so
  the `Language:` header parsed as garbage rather than as `et`.

  Each entry is now translated for its own meaning, with the long strings
  checked against the `.heex` that renders them: the `Settings → Integrations`
  hint keeps its arrow and `Email #%{uuid}` keeps its interpolation. Product
  names (AWS, SES, Amazon SES) stay untranslated.

### Changed

- Dependency updates (`phoenix_kit` 2.2.0, `phoenix` 1.8.10, `hackney` 4.7.3).

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Added

- The webhook CSRF regression test now pins the **before** state too (PR #28).
  A fixture router wires the webhook through a `:browser` pipeline with
  `protect_from_forgery` — the exact shape the bug had — and asserts a cold POST
  raises `InvalidCSRFTokenError`. The previous test asserted only that a cold
  POST returns 200, which would also pass if the route had never gone through
  `:browser` at all; it silently depended on `Routes.generate/1` staying broken
  to mean anything.

## 0.1.23 - 2026-08-07

### Security
- **Single-use auth tokens no longer reach the email log.** PhoenixKit stores only a SHA-256 hash of every emailed token, so the raw token existed in exactly one place — the message sent to the user. Logging the body put it back in the database in plaintext, behind the `emails` permission that the Admin role holds by default. That turned the log into a credential store: request a password reset for any address on the public forgot-password page, then read the working link out of `/admin/emails` and use it, never touching the target's mailbox. The new `SecretScrubber` replaces the token with `[REDACTED]` on the way IN, before the row is written, so exports, S3 archival, backups and support dumps are all covered by the one control. It covers every auth URL core emails — reset, confirmation, email change, magic link, magic-link registration (path segment) and organisation invitation (`?invitation=`) — and leaves the link itself in place, so the row still shows what was sent and where it pointed. The send queue is deliberately excluded: `Queue.serialize/1` args are the message in transit, and redacting there would mail the recipient a dead link. (#27)

### Fixed
- **The scrubber could silently fail open on a slash-heavy body.** Its URL pattern reached the auth segment through two overlapping lazy quantifiers that both consume `/`-delimited path segments, giving a quadratic number of ways to split the path at every start position. Past roughly 20 KB of such text PCRE hit its internal backtracking limit — and `String.replace/3` signals nothing on that, it returns the subject **unchanged**. A real token further down the same body was then written to the log in plaintext while the row looked scrubbed, which is worse than not scrubbing at all, because nothing downstream can tell the difference. The pattern now anchors on `/<auth-segment>/` instead of on `https?://…` and has no quantifier that spans a path separator, so matching is linear: the 82 KB case went from 105 ms and leaking to 1.4 ms and redacted. Nothing is lost — every auth route core emails puts the token immediately after the segment, and the locale and host-app prefixes the old middle group was written for sit *before* the segment, not between. (#27)
- The path pattern is case-insensitive, matching the query pattern, which already was. A host app that mounts its routes with any uppercase in the path had the query form scrubbed and the path form leaked. (#27)

### Internal
- Post-merge review of #27: `dev_docs/pull_requests/2026/27-scrub-single-use-auth-tokens/CLAUDE_REVIEW.md`. Cross-checked the segment whitelist against every `:token` route core registers and every URL its notifiers actually send — the whitelist is complete, and the three uncovered token routes (on-screen QR login, the post-verify redirect, signed asset URLs) are correctly out of scope. The route-enumeration test gained `confirm-email`, the one whitelist entry that is a prefix collision with another (`confirm`) and so only matched by backtracking; the alternation now lists it first. Rows written before this release still hold their tokens — not backfilled, and why not is recorded in the review.

## 0.1.22 - 2026-08-06

### Fixed
- **Requires `phoenix_kit ~> 1.7.231`** — the release that ships `PhoenixKitWeb.Live.UrlState`. 0.1.21 adopted that module for the blocklist screen but left the floor at `~> 1.7.217`, which resolves any core from 1.7.217 upward. Resolving anything in 1.7.217–1.7.230 gives a core with no such module, and `use` of a missing module is a compile error — one that can only appear in a **consumer's** build, since this package's own lockfile has always been well above the floor, so nothing here ever failed. It bites an app whose `mix.lock` already pins an older core (Hex keeps the locked version, because the stale requirement accepts it) or one that pins core itself. The floor was corrected in #26, but 0.1.21 had already been published with the old requirement, so this release is what actually delivers the fix. (#26)

### Internal
- Post-merge review of #26: `dev_docs/pull_requests/2026/26-core-version-floor/CLAUDE_REVIEW.md`. Verified the chosen floor against the Hex tarball rather than the changelog alone — `url_state.ex` is byte-identical in 1.7.231 and the locked 1.7.232, and 1.7.232 adds no modules this package references, so 1.7.231 is both sufficient and not needlessly high.
- The `:phoenix_kit` comment in `mix.exs` states one floor again. The #26 rationale had been appended below the older 1.7.217 paragraph, leaving two consecutive comments each opening "X is the floor" — the first of them wrong, in the one comment whose job is to stop someone lowering the pin. Superseded requirements are now labelled as history.

## 0.1.21 - 2026-08-05

### Added
- **The blocklist screen's state lives in the URL.** Search, reason filter, status filter, sort column, sort direction and page are declared through `PhoenixKitWeb.Live.UrlState` and encoded into the query string (`?q=&reason=&status=&sort=&dir=&page=`), so a filtered list is a real address: shareable, bookmarkable, reproduced by a reload, and walked by the browser's Back button instead of being left. Values equal to their default are omitted, so an unfiltered list stays at the bare path. (#25)

### Fixed
- **An out-of-range `?page=` no longer renders one button per skipped page.** With `page` now arriving from the URL rather than only from the pagination buttons, it could point far past the end of the list — `?page=900` on a two-page list, up to the decoder's ceiling of 1,000,000. The template's `max(1, @page - 2)..min(@total_pages, @page + 2)` window then inverted into a *descending* range, emitting one `<button>` per skipped page: ~1M DOM nodes from a single crafted or stale link. The page is clamped to the available range before the query runs, and the window carries an explicit `//1` step. (#25)
- **The blocklist's sortable-column whitelist is declared once.** The URL decoder and `validate_sort_by/1` had separate copies of the same four atoms; a column added to one but not the other is accepted by the header click and then silently dropped by the URL, leaving the click with no visible effect and no error anywhere — the same failure the reason filter hit before merge. (#25)
- The blocklist no longer loads its list, count and statistics inside `mount/3`, where LiveView's two-phase mount ran every one of those queries twice per page load. The load moved to the URL-state callback, so one code path serves the first render, a shared link and a Back press alike. (#25)

### Changed
- Pruned eight stale `mix.lock` entries (`igniter`, `sourceror`, `rewrite`, `spitfire`, `owl`, `ex_ast`, `glob_ex`, `text_diff`) left behind by an earlier dependency upgrade. `mix precommit`'s `deps.unlock --check-unused` step was failing on them.

## 0.1.20 - 2026-07-31

### Added
- **Universal event-tracker lifecycle.** Every provider's delivery-event poller now implements one `EventTracker` behaviour (`eligible?/0` — is there a working event source at all — split from `enabled?/0` — the operator's toggle), is listed in a compile-time `EventTrackerRegistry`, and has its self-scheduling Oban chain started and stopped by a single stateless `EventTrackerReconciler` enforcing "iff `should_run?/1`, exactly one chain exists". The invariant is enforced at the database by Oban's own `unique`, so simultaneous reconciles on several nodes collapse to one chain. Adding a provider is: implement the behaviour, add the module to the registry. (#24)
- **`EventTrackerReconcileWorker`** — a low-frequency Oban `Cron` entry in its own `event_tracker_reconcile` queue, and the correctness backbone of the above: it is the only trigger that can resurrect a chain that died or was never started (a `SendProfile` change emits no PubSub today). Boot and settings-toggle reconciles are latency polish on top. **Requires new host config** — see the installer output. (#24)
- **Unified "Delivery Event Tracking" settings section**, one row per registered tracker: integration count, tracking toggle, a four-state badge (Active / Idle — no integration / Off / Stalled) with a per-state hint, editable interval, last poll, queued-job count, Brevo's per-account polling opt-out, and Poll now / Restart actions. Replaces the polling controls that lived in the Amazon SES & SQS and Brevo Events sections; the latter is removed. (#24)
- `Log.exists_by_any_message_id?/1` and `Emails.email_log_exists?/1` — a cheap indexed existence check across `message_id` and `aws_message_id`, no preloads, no struct load.

### Fixed
- **Brevo polling on a shared account no longer floods the log.** A Brevo account may be shared with other senders, so most polled events are for mail this app never sent; each one used to be dragged through the SES/SNS processor's not-found path and surfaced as a loud `[SYNC ISSUE] ... unknown email` error, repeating every cycle until midnight. Such events are now skipped at `:debug` after a single existence check, with one `:info` summary per fetched page so the path stays observable — a page that is suddenly all skips is the signal. (#24)
- **SES no longer starts a poller with no queue URL.** The queue-URL precondition that lived in the supervisor's own boot gate is folded into `eligible?/0`, so a deployment with SES credentials and the toggle on but no queue configured no longer starts a chain at boot, has it resurrected every reconcile tick, and logs "SQS queue URL not configured" forever while the panel reports it as running. That state now reads "Idle — no integration". (#24)
- The supervisor's two boot-gate predicates delegate to `EventTracker.should_run?/1` instead of hand-copying the gate — the copies had already drifted in both directions (SES's omitted the sender-aware gate, Brevo's omitted the active-integration requirement).
- **Post-merge review fixes:** the panel's Last-poll column read "Never polled yet" for a healthy Brevo chain, because the generic timestamp came from Oban's `completed` job history and `Oban.Plugins.Pruner` deletes those after 60s — well under Brevo's 30s floor and 120s default. `EventTracker` gained an optional `last_polled_at/0` callback, which `BrevoPollingManager` answers from the durable setting its job already writes every cycle.
- **Post-merge review fixes:** the panel's tracking toggle called the managers directly, and `enable_polling/0` inserts a chain without consulting `eligible?/0` — so turning SES on with no queue URL queued a chain for a tracker with nothing to poll ("Idle — no integration" beside a non-zero Queued count), and turning tracking off left its queued job behind. Both only self-corrected on the next reconcile tick, or never on a host that had not wired the Cron. The toggle now reconciles.
- **Post-merge review fixes:** "Poll now" flashed success for a tracker with no working event source, having queued a forced job that could only wake up, fail its own eligibility gate and do nothing — the failure mode the button exists to prevent. It now refuses and says why.
- **Post-merge review fixes:** the interval editor bound HTML `step` to the tracker's minimum, so the browser rejected every value that was not a multiple of it (Brevo: 30s, 60s, 90s and nothing between) while the server accepted them.

### Changed
- **New host Oban configuration is required** for the reconcile backbone: a `event_tracker_reconcile: 1` queue and a `{"*/2 * * * *", PhoenixKit.Modules.Emails.EventTrackerReconcileWorker}` crontab entry (plus `brevo_polling: 1` if it was missing). Without them a tracker whose chain dies is never resurrected until the next app restart. `mix phoenix_kit_emails.install` prints the full snippet.
- The installer's printed `plugins:` list now includes `Oban.Plugins.Pruner` and `Oban.Plugins.Lifeline`, with an instruction to merge rather than replace an existing list. Lifeline is load-bearing here, not decorative: a poller job orphaned in `:executing` by a node that died mid-cycle is a permanent unique conflict for the reconciler, which can then never insert a successor — while the panel, counting that same row, keeps reporting the tracker as Active.
- `email_create_placeholder_logs` no longer applies to polled Brevo events. On a shared account, creating a log row per orphaned event means materialising other senders' traffic in this app's email log. SES, where every event is by definition our own mail, is unchanged.
- Dialyzer runs against a `.dialyzer_ignore.exs` carrying one narrowly-scoped entry for a pre-existing Gettext/Expo opaqueness false positive in the generated backend module.

## 0.1.19 - 2026-07-29

### Added
- **Outgoing send queue.** `Queue` implements core's optional `PhoenixKit.Email.Provider.maybe_enqueue/2` callback (floor raised to `phoenix_kit ~> 1.7.217`), so every outgoing message — including mail the host app sends through its own statically configured mailer — is offered to the `:emails` Oban queue and delivered by `SendJob` (`max_attempts: 5`) instead of on the request. Every decline is "send it inline now", never an error: a disabled system, `email_queue_enabled` off, no `:emails` queue in the **host's** Oban config (a package cannot add one, and `Oban.insert/1` would happily store a job nobody drains), a per-message `queue: false`, authentication mail, attachments, an `Oban.insert/1` error, and even a raise or a DBConnection exit all fall through to an inline send. Delivery is at-least-once, which is why authentication mail is excluded by default. (#22)
- **System-status card** in Settings → Email Sending → Email Tracking. Reports what the module is *doing*, not what it is configured to do: whether anything is being logged and why not (a `from` address that fails the `Log` schema's own format rule makes every insert fail, and the interceptor swallows that by design), which mailer or integration messages actually leave through, the queue's state and depth, and today's logged/sent/failed/queued counts. (#22)
- **Two switches for the queue** — "Queue Outgoing Emails" (`email_queue_enabled`) and "Queue Authentication Emails Too" (`email_queue_auth_mail`) — in the same settings section as the card. Post-merge review: the queue shipped default-on and reported read-only, with no way to turn it off short of editing the settings table.

### Changed
- **Behavioural default for existing installs:** `email_queue_enabled` defaults to **true**, so a host that has (or later adds) an `emails: N` Oban queue starts routing eligible outgoing mail through Oban after this upgrade. Authentication mail and messages with attachments are still sent inline. Hosts with no `:emails` queue are unaffected — nothing is queued and mail is sent as before.
- `Interceptor.intercept_before_send/2` leaves a message that already carries `X-PhoenixKit-Log-Id` alone, so the queue worker's re-send updates the existing log row rather than writing a second one and stranding the first at "queued".
- `Log.email_format_regex/0` exposes the sender-format rule the changeset validates with, so the status card's warning cannot drift from the validation that causes the failure.
- Queued mail carries its recipients, subject and bodies in the Oban job's args until the row is pruned — independent of `email_save_body` and `email_retention_days`, which only govern this module's own tables. Configure `Oban.Plugins.Pruner` accordingly; documented on `Queue.serialize/1`.
- Callers that route a send through an explicitly chosen integration (`Mailer.deliver_via_integration/3` with a non-default uuid) must pass `queue: false`: core hands the queue only the integration's `:provider`, never its uuid, so a queued re-send resolves the *default* transport. Documented in `Queue`'s moduledoc and `AGENTS.md` until core carries the uuid.

### Fixed
- Test sends are never queued (`skip_queue: true` on the template-editor preview and both `Provider` test-email paths). A queued test would flash "sent successfully" the moment Oban accepted the job — before any relay had seen it, and while a later failure went unreported. (#22)
- A raise inside a queued send (an adapter that throws instead of returning `{:error, _}`, a pool timeout) never reaches core's after-send hook, so the log row stayed at "queued"; after the fifth attempt Oban discarded the job and nothing ever closed the row out. `SendJob` now marks the row failed on the last attempt and reraises, leaving Oban's own recording, backoff and discard untouched.
- The card's "no `:emails` Oban queue" warning no longer contradicts the Queue row it sits above when the whole email system is disabled (it is gated on `Queue.status/0 == :no_oban_queue`, the one state that means "on, and cannot run").
- A default send integration saved without a name rendered a blank "Sending through" value instead of the card's own fallback label.
- Three dialyzer errors that made `mix precommit` fail on the merged branch: an unreachable `log_uuid/1` fallback clause in `Queue`, a `map() === nil` guard in `SendJob`, and an `is_binary/1` branch in `Status` that core's `get_from_email/0` typing proves dead (rewritten to stay nil-safe at runtime).

## 0.1.18 - 2026-07-27

### Fixed
- Brevo event polling no longer stays dead across app restarts when `brevo_events_enabled` is still on but no Oban job row survived (crash before `schedule_next_poll/1`, wiped jobs table, etc.). The supervisor now re-seeds the Brevo chain at boot the same way it already re-seeds SQS — via `BrevoPollingManager.enable_polling/0` after Oban is ready. Zero active Brevo profiles is fine; the job no-ops each cycle and still records `last_polled_at`.

### Changed
- `Supervisor.system_status/0` also reports `brevo_polling_status` (alongside the existing SQS `polling_status`).
- Clarified `BrevoPollingManager` docs: `poll_now/0` bypasses only the `brevo_events_enabled` toggle, not the sender-aware profile gate or `Emails.enabled?/0`.

## 0.1.17 - 2026-07-26

### Changed
- Both polling chains (`SQSPollingJob`, `BrevoPollingJob`) now guarantee "exactly one queued future job" with Oban's own uniqueness instead of a manual delete-then-insert. The workers carry `unique: [period: :infinity, states: [:scheduled]]` (`:executing` deliberately excluded — Oban's conflict check has no self-exclusion, so a self-rescheduling job would match its own row and stall the chain every cycle), and the managers' immediate inserts use a per-call `unique: [:available, :scheduled]` + `replace: [scheduled_at]` override so enabling while a tick is already queued moves that job up rather than appending a second one. `cancel_scheduled/0` is gone from both jobs, and `disable_polling/0` no longer deletes anything — the queued job's own `should_poll?/0` check ends the chain on its next tick. (#21)
- `BrevoPollingManager.poll_now/0` now inserts `args: %{"forced" => true}`, which `BrevoPollingJob.perform/1` honours by running one cycle regardless of the `brevo_events_enabled` toggle (still subject to `Emails.enabled?/0` and the sender-aware gate). The distinct args also keep manual polls in their own uniqueness namespace, so they never move or cancel the regular chain's next scheduled tick. (#21)

### Fixed
- `SQSPollingManager.poll_now/0` was a silent no-op whenever SQS polling was disabled — the one case an operator is most likely to use it. It inserted a job with the regular chain's args, which `SQSPollingJob.perform/1` then dropped on its `should_poll?/0` gate, even though the manager logged "Polling is disabled, but executing manual poll". It now inserts a forced job (`args: %{"forced" => true}`) that bypasses the `sqs_polling_enabled` toggle for that single cycle, mirroring Brevo; `Emails.enabled?/0`, the SES-events switch, and the sender-aware profile gate are still enforced, and `schedule_next_poll/1` still refuses to resurrect the chain. (#21)
- `SQSPollingManager.poll_now/0` also reset the regular chain's cadence: sharing the regular chain's args made its `unique`/`replace` insert conflict with the already-scheduled next tick and move that job's `scheduled_at` to now. Manual polls are now independent of the chain. (#21)

## 0.1.16 - 2026-07-20

### Changed
- `BrevoPollingJob` no longer re-fetches the fixed `[yesterday, today]` window from offset 0 every cycle. Each integration's progress is now a persisted `%{date, offset}` watermark (stored via `PhoenixKit.Settings`' JSON-by-prefix helpers), so a cycle queries a single day at its last-known offset instead of re-paying the re-fetch + dedup-lookup cost for every already-processed event, and a sender producing more events than one cycle's page cap covers can still reach its newest events over successive cycles instead of never catching up. A trailing one-day re-check (its own small page budget, independent of the forward walk's) guards against Brevo's ~30-60s indexing lag and undocumented `startDate`/`endDate` timezone. Watermarks for integrations no longer active (deleted or excluded from polling) are pruned each cycle. (#20)

### Fixed
- The above watermark's offset for *today* specifically never advanced past a non-empty short page — every cycle re-fetched and re-processed the same tail of today's events for as long as today's total stayed under the page limit, which is the common case at normal volumes. Now advances by the number of events actually returned. (#20)

## 0.1.15 - 2026-07-19

### Changed
- Bumped `beamlab_ex_aws_sqs` to `~> 5.0`, declared as `{:ex_aws_sqs, "~> 5.0", hex:
  :beamlab_ex_aws_sqs}`, matching the same bump in `phoenix_kit` (>= 1.7.205). v5.0.0
  renamed the compiled OTP app back to `:ex_aws_sqs` (only the Hex package name is
  `beamlab_ex_aws_sqs`). No code changes — `ExAws.SQS`'s public API is unchanged.

## 0.1.14 - 2026-07-19

### Fixed
- `Emails.aws_configured?/0` always returned `true` regardless of actual configuration: `get_aws_access_key/0`/`get_aws_secret_key/0` return `nil` (not `""`) when unconfigured, but the check only compared against `""` (`nil != ""` is `true` in Elixir). This silently affected `sync_email_status/1`, `fetch_sqs_events_for_message/1`, `fetch_dlq_events_for_message/1`, `current_provider/0`, and the "AWS Configured" badge on the Amazon SES & SQS settings section — all now correctly reflect whether AWS credentials are actually present. (#19)

### Changed
- `SQSPollingJob` now gates polling on whether SES is actually the thing sending mail right now, mirroring `BrevoPollingJob`'s sender-aware gate: polling requires either an enabled `SendProfile` pointed at an `"aws_ses"` integration, or `Emails.aws_configured?/0` as an explicit override for deployments that predate the `SendProfile` system (legacy Settings/env-var credentials, or a bare `aws_ses` Integrations connection with nothing pointed at it). (#19)

## 0.1.13 - 2026-07-19

### Fixed
- The `/webhooks/ses` route was piped through the host app's `:browser` pipeline, which (per the documented default) includes `protect_from_forgery`. AWS SNS delivers webhook notifications as a cold, session-less POST with no CSRF token, so every notification 403'd with `Plug.CSRFProtection.InvalidCSRFTokenError` before ever reaching `WebhookController`. The route now runs through its own minimal `:phoenix_kit_emails_webhook` pipeline (just `plug :accepts, ["html"]`, no session/CSRF plugs), mirroring the equivalent fix in `phoenix_kit_newsletters`'s one-click-unsubscribe route. (#17)

## 0.1.12 - 2026-07-19

### Changed
- AWS SES credentials now resolve through `PhoenixKit.Integrations` (an encrypted `aws_ses` connection) instead of being stored as plaintext Settings rows. `get_aws_access_key/0`, `get_aws_secret_key/0`, and `get_aws_region/0` prefer the selected Integrations connection and fall back to the legacy Settings/env-var path, so an unmigrated install keeps sending. `migrate_legacy/0` moves an existing key/secret into a new connection once, idempotently, without deleting the legacy Settings rows (an operator confirms the new connection works before blanking them manually).
- The combined credential lookup is cached for 60s (`PhoenixKit.Cache`) so building a send-path AWS config no longer costs 3 Settings reads plus 3 decrypt round-trips per email; `invalidate_aws_credentials_cache/0` is called wherever the selected connection changes.
- Settings moved off this module's own `/admin/settings/emails` tab and now contributes two sections ("Email Tracking", "Amazon SES & SQS") to core's unified `/admin/settings/email-sending` page via `email_settings_sections/0`. `settings.ex`/`settings.html.heex` are gone, replaced by `web/settings_sections/`.
- Requires `phoenix_kit ~> 1.7.190` (the release that carries the `email_settings_sections/0` seam).

### Fixed
- SES bounce classification matched `"Temporary"` for soft bounces, but SES actually sends `"Transient"` — every soft bounce was silently recorded as a hard one. Both strings are now accepted.
- Hard (permanent) bounces are now added to the rate limiter's blocklist, so a bounced address stops receiving future sends instead of bouncing again on the next campaign.
- `PhoenixKit.Modules.Emails.Provider` implements `PhoenixKit.Email.Provider` but never declared `@behaviour`/`@impl` — a renamed or dropped callback in core would have compiled clean here and only failed at runtime. Declared, with `@impl` on all 14 callbacks.
- Boot-time `migrate_legacy/0` no longer makes a live SES API call (`GetSendQuota`, up to 15s) to validate the migrated connection — the credentials were already sending mail before the migration ran, so there was nothing to verify that the first real send wouldn't; this was blocking app startup on network egress.
- `mix hex.publish` refused to build the package with `hackney` declared as `override: true` ("Can't build package with overridden dependency hackney, remove `override: true`"). The override dates back to when `ex_aws_sqs` pinned `hackney ~> 1.9`; since 0.1.11 swapped that for `beamlab_ex_aws_sqs` (which declares no hackney dependency at all), nothing in the tree needs hackney forced above its natural resolution — removed, `mix.lock` unchanged (still resolves 4.6.0).

### Added
- First real test infrastructure for this package (`test/support/data_case.ex`, `test_repo.ex`, `config/test.exs`) — the credential-resolution and SQS bounce/blocklist paths now have DB-backed integration tests instead of being untestable.

## 0.1.11 - 2026-07-12

### Security
- **`ex_aws_sqs` replaced with [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs), matching the switch already made in core (`phoenix_kit` 1.7.188/189).** `ex_aws_sqs` (last released Jan 2023, since archived upstream) pins `hackney ~> 1.9`, which was blocking the `hackney ~> 4.0` upgrade needed to clear a batch of hackney CVEs and made `mix hex.audit` fail on every `precommit`/release. The fork is a maintained drop-in with the same public API (`ExAws.SQS`) and no hackney dependency, but switches SQS from the legacy Query/XML protocol to AWS's JSON protocol, which changes response shapes (`%{"Messages" => [...]}` with string keys like `"ReceiptHandle"`, instead of `%{body: %{messages: [...]}}` with atom keys). `SQSPollingJob` already matched both shapes defensively; `Emails.poll_sqs_for_message/5` and `poll_dlq_for_message/5` (used by the email-details "find delivery events" lookup) only matched the old shape and were updated to match both. `mix hex.audit` now reports zero advisories. Pulls in `phoenix_kit` ~> 1.7.189 and `ex_aws` 2.7.x as part of the same hackney 4.x resolution.

## 0.1.10 - 2026-07-12

### Changed
- Emails admin UI: Settings/Dashboard now share phoenix_kit's core `<.input>`/`<.checkbox>` components instead of hand-rolled markup, section headers sized to match core's other Settings pages, and the breadcrumb reads "Settings / Emails" instead of "Emails Settings".
- AWS Region is now a static searchable dropdown (backed by the `aws_regions` package, now a direct dependency) instead of manual entry plus a "Load regions" AWS API call.

### Fixed
- SES Configuration Set, SNS Topic ARN, and SQS Queue URL/ARN/DLQ settings were only visible in the AWS Configuration card after enabling "AWS SES Events Options", even though "Setup AWS Infrastructure" could already populate them without that toggle — they're now always visible/editable alongside the rest of AWS Configuration.
- The Dashboard's "System Status" card showed a hardcoded "Active" badge regardless of whether email delivery was actually configured.

### Added
- Mailer adapter transparency: `Utils.mailer_adapter_status/0` detects the real Swoosh adapter using the same built-in/delegated-mailer resolution logic as `PhoenixKit.Mailer` itself, and both Settings and the Dashboard now show what's actually configured — plus a copy-pasteable `config.exs` snippet when it's missing or isn't Amazon SES — instead of silently assuming AWS SES everywhere.

## 0.1.9 - 2026-07-08

### Fixed
- `Event.create_event/1` unconditionally inserted with `mode: :savepoint` (added in 0.1.8 to protect `Log.mark_as_opened/2`/`mark_as_clicked/3`'s transactional callers). `:savepoint` mode is not a no-op outside a transaction — it requires one to nest a savepoint in, and raises `DBConnection.TransactionError: transaction is not started` otherwise. Every event created by the SQS processor's non-transactional paths (delivery, bounce, complaint, open, click) was hitting this, so the `phoenix_kit_email_events` audit trail silently stopped populating for messages processed via SQS. Fixed by only requesting `:savepoint` mode when `repo().in_transaction?()` is true.

### Changed
- Dependency bumps (`mix.lock`): `phoenix_kit` 1.7.172 → 1.7.178, plus patch-level updates to `phoenix`, `phoenix_live_view`, `db_connection`, `swoosh`, `mint`, and others.

## 0.1.8 - 2026-06-24

### Added
- Admin UI overhaul for the Emails module: page title/subtitle moved into the admin shell top bar; a daisyUI table toolbar across Emails/Templates/Queue/Blocklist (dropdown filters, a persistent inline search with inline clear, action buttons); clickable column-header sorting (server-side, URL-backed, field-whitelisted) on the contexts that support ordering; body-row click-to-open (Emails/Queue → Details, Templates → edit); a drag-and-drop column customizer on Emails; and a "Get update on this email" per-row status sync. (#13)
- `Send Test` now renders and sends the seeded `test_email` system template (falling back to a built-in body) and records `template_name`, the sending admin's `user_uuid`, and `source_module: "emails"`, so the email Details page shows the template, user, and module. (#13)

### Fixed
- Webhook security (SNS): the signing-certificate URL is locked to `sns.<region>.amazonaws.com` with a `/SimpleNotificationService-*.pem` path before any fetch (blocks forged-cert signature bypass and SSRF); `SignatureVersion` is honored (SHA-1 vs SHA-256); `X-Forwarded-For` is trusted only from configured proxies (new `webhook_trusted_proxies` setting, default empty); and `confirm_subscription/1` actually issues the SubscribeURL GET. (#12)
- Event ingestion: open/click events no longer overwrite terminal statuses (bounced/complaint/rejected/failed); event creation is idempotent via DB unique constraints with graceful `{:ok, :duplicate_event}` mapping; open/click dedup on `occurred_at` preserves multiple distinct engagements while collapsing exact SQS redeliveries; `opened_at`/`clicked_at` are now recorded. (#12)
- SQS pipeline: placeholder logs are inserted directly, bypassing the sampling roll that previously returned `{:ok, :skipped}`, crashed callers, and re-cycled messages forever; the Oban poller is collapsed to exactly one self-healing chain (always self-schedules while enabled, backs off on misconfiguration instead of dying); `Task.yield_many` prevents a slow task from aborting a whole batch; sub-second polling intervals are rejected. (#12)
- The dedup insert in `Event.create_event/1` runs with `mode: :savepoint`, so a unique-constraint violation inside `Log.mark_as_opened/2`/`mark_as_clicked/3`'s transaction no longer aborts the transaction and silently rolls back the status update.
- Analytics: `get_stats_for_period/2` now counts the `complaint` status (it previously matched a `complained` string that is never written, so the metric was always 0) and runs as one grouped query instead of seven aggregate round-trips. (#12)
- The Emails table column customizer validates column ids against the available-column set before persisting, so a crafted client event can no longer store an unknown column. (#13)
- List sorting applies a deterministic UUID (primary-key) tiebreaker, so rows with equal primary-sort values page consistently across the Emails, Templates, and Blocklist lists. (#13)

### Changed
- Archiver body compression truly streams via `Repo.stream` in a transaction (was loading the full result set and only compressing the first batch); CSV exports route every cell through formula-injection + RFC 4180 escaping; `list_logs` no longer preloads `[:user, :events]` on the admin hot path; PubSub status updates refresh a single row instead of reloading the list. (#12)
- Adopt `phoenix_kit` 1.7.165 (provides the core migration backing the email-event dedup unique indexes).

## 0.1.7 - 2026-06-23

### Added
- Live-update the Emails admin list on delivery-status changes via PubSub. `Log.update_log/2` broadcasts a lightweight `{:email_log_updated, …}` event only when a log's status actually changes; the emails LiveView refreshes just the affected on-screen row (no 30-day stats recompute). Best-effort — a PubSub failure can never break the DB write. (#11)

### Fixed
- Consolidate SQS polling onto a single Oban-based poller: remove the legacy 842-line `SQSWorker` GenServer. `SQSPollingJob` + `SQSPollingManager` are now the sole poller and runtime control surface (enable/disable without an app restart). (#11)
- Self-scheduling no longer stalls: the polling job's `unique` constraint excludes running jobs, so an executing job can enqueue its successor and a crash-orphaned job can't permanently block new inserts. (#11)
- SQS messages no longer re-cycle forever: `delete_message/3` returns failures instead of swallowing them as `:ok`, reads both string and atom receipt-handle keys, and won't count an undeleted message as processed. (#11)
- The admin SQS-polling toggle now starts/stops the poller at runtime (routed through `SQSPollingManager`) instead of only persisting the flag and waiting for the next boot. (#11)
- Provider detection classifies a message as `aws_ses` when an SES configuration set is configured, even when the host app sends through its own Swoosh mailer. (#11)
- Post-merge review fixes: compile clean under `--warnings-as-errors` with Oban 2.23 (narrow the polling job's `unique` states to `[:scheduled]`), satisfy `credo --strict` for the new broadcast helper, and drop a stale retired `earmark` entry from the lockfile.

### Changed
- Refresh dependency lockfile (notable bumps: `oban` → 2.23, `phoenix_kit` → 1.7.164, `phoenix_live_view` → 1.2, `swoosh` → 1.26, `tesla` → 1.20, `bandit` → 1.12, `req`).

## 0.1.6 - 2026-05-25

### Added
- Route all 9 Emails admin LiveViews through the per-module `PhoenixKit.Modules.Emails.Gettext` backend, so this package's `ru`/`et` catalogues resolve at render time instead of falling back to English. Extends gettext coverage across the full template surface (IAM/SES setup walkthrough, template editor, blocklist, metrics, queue); `default.pot` grows to 447 msgids. (#9)
- Localise ~100 `put_flash` messages across the Emails LiveViews (settings toggles, errors, confirmations) with `%{var}` interpolation bindings and `en`/`ru`/`et` translations. (#10)

### Fixed
- Correct gettext catalogue mis-fills from the bulk regeneration: 12 `en` entries where `msgstr` ≠ `msgid`, and 7 `ru`/`et` cross-locale mistranslations (e.g. the "Setup AWS Infrastructure" button rendering a stray "3." step prefix; Archive/Clone template tooltips reading "New Template"; `Queued` status showing "Queue").

### Changed
- Require `phoenix_kit ~> 1.7.106` (per-module Gettext backend API).
- Refresh dependency lockfile (notable bumps: `phoenix_kit` 1.7.108→1.7.120, `ecto`/`ecto_sql` 3.13→3.14, `fresco` 0.1→0.6 plus new `etcher`, `tesla` 1.17→1.18, `hammer` 7.3→7.4, `bandit`, `plug`, `req`).

## 0.1.5 - 2026-05-12

### Added
- Wrap Emails settings and email tracking UI strings in `gettext` (47 new msgids in `default.pot`, `en`, `ru`, `et` catalogues). Covers tracking-options toggle labels, data retention block, privacy notice, current configuration table, tracking-benefits headers, IAM/SES setup walkthrough, and remaining placeholders.

### Changed
- Widen Emails settings page to use the full container width on wide screens (drop the `max-w-4xl mx-auto` wrapper). Short numeric inputs keep their `max-w-xs` caps.
- Refresh dependency lockfile to latest compatible versions (notable bumps: `finch` 0.21→0.22, `postgrex` 0.22.1→0.22.2, `swoosh` 1.25.1→1.25.2, `phoenix_kit` 1.7.106→1.7.108, `telemetry` 1.4.1→1.4.2).

## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKit.Modules.Emails.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

### Fixed
- Suppress `EmailInterceptor` Logger warnings when the configured Swoosh adapter is not AWS SES.

### Changed
- Refresh dependency lockfile to latest compatible versions (notable bumps: `bandit`, `db_connection`, `decimal`, `ecto`, `ex_doc`).

## 0.1.3 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md


All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-04-02

### Fixed

- Changed `css_sources/0` return type from atom to binary to match `PhoenixKit.Module` behaviour callback spec.

### Changed

- Rewrote README to match sibling project structure with full documentation.

## [0.1.1] - 2026-03-27

### Fixed

- Removed `@behaviour` and `@impl` annotations from `Provider` to fix compilation warnings (behaviour defined in host app).
- Suppressed `Hammer` undefined module warning in `WebhookController`.

### Changed

- Rewrote install task to automatically add Tailwind CSS `@source` directive to `app.css` (idempotent).
- Updated `.gitignore` with standard Elixir project entries.

## [0.1.0] - 2026-03-24

### Added

- Initial extraction from PhoenixKit core into a standalone package.
- `PhoenixKit.Email.Provider` behaviour with 14 callbacks.
- AWS SES integration for email sending via SMTP and API.
- AWS SNS webhook processing for bounce, complaint, and delivery notifications.
- AWS SQS polling for asynchronous event ingestion.
- Email tracking and analytics (opens, clicks, deliveries, bounces, complaints).
- 9 admin LiveViews: dashboard, logs, templates, campaigns, recipients, settings, domains, blocklist, tracking.
- Email template management with variable interpolation.
- CSV and JSON export for email logs and analytics.
- Swoosh interceptor for automatic email tracking.
- Rate limiting on webhook endpoints via Hammer.
- SNS signature verification for webhook security.
- CSV formula injection protection in exports.
- Install mix task (`mix phoenix_kit_emails.install`).

[0.1.2]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.2
[0.1.1]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.1
[0.1.0]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.0
