# Code Review: PR #22 — Add an outgoing send queue and a system-status card

**Reviewed:** 2026-07-29
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/22
**Author:** Timujeen (timujinne)
**Head SHA:** cfb8f623b393965a8b7f364a86b74c3d3ae80afe
**Status:** Merged (reviewed post-merge, on `main`)

## Summary

Adds an outgoing send queue and the settings-page status card that makes it (and the
rest of the module) observable:

- **`Queue`** — implements core's optional `PhoenixKit.Email.Provider.maybe_enqueue/2`
  callback. Decides inline-vs-queued behind six gates (`email_enabled`,
  `email_queue_enabled`, host `:emails` Oban queue present, per-message `queue: false`,
  authentication mail, attachments) and serializes the `Swoosh.Email` into JSON job args.
  Every decline — and every enqueue failure, including a raise or a DBConnection exit — is
  `:continue`, i.e. "send it inline now".
- **`SendJob`** — Oban worker (`queue: :emails`, `max_attempts: 5`) that rebuilds the
  message and re-sends it with `skip_queue: true` + `already_intercepted: true`.
- **`Status`** — `summary/0`, one snapshot of what the module is actually doing, rendered
  as a card in the Email Tracking settings section.
- **`Interceptor`** — skips logging a message that already carries `X-PhoenixKit-Log-Id`,
  so the worker's re-send updates the existing log row instead of writing a second one.
- **`Log.email_format_regex/0`** — the sender-format rule, exposed so the card can warn
  about a `from` address that would make every log insert fail.
- `mix.exs` floor raised to `phoenix_kit ~> 1.7.217` (installed: 1.7.218) for the callback.

An earlier review by GLM-5.2 (`GLM_REVIEW.md`) is in this directory; its three majors
(test sends being queued, the un-bumped floor, no tests) were addressed in follow-up
commits before the merge, and I re-verified all three as fixed. This review covers the
merged state and does not repeat them.

## Issues Found

### 1. [BUG - HIGH] Core's own "Send test email" button still reports success for a queued message — NOT FIXED (upstream)

**File:** `deps/phoenix_kit/lib/phoenix_kit_web/live/settings/email_sending.ex:137` (phoenix_kit 1.7.218)

The PR correctly fixed its own three test-send paths (`provider.ex:136`, `provider.ex:155`,
`template_editor.ex:390` now pass `skip_queue: true`). There is a fourth, in core, on the
**same settings page this PR's status card renders on**:

```elixir
case Mailer.deliver_email(email) do          # no skip_queue: true
  {:ok, _result} ->
    put_flash(socket, :info, gettext("Test email sent to %{recipient}", recipient: recipient))
```

That email has no attachments and no `campaign_id`, so with this package installed and the
queue default-on it is enqueued, `deliver_email/2` returns `{:ok, %{id: ref, queued: true}}`,
and the operator is told the test email was sent before any relay has seen it — and a later
worker failure is never reflected in that flash. The operator's primary "is sending working?"
button becomes exactly the "enabled ≠ working" lie the status card was built to expose.

**Not fixed here** — the call site is in `phoenix_kit`, not in this package, and this package
has no signal that distinguishes that send from ordinary app mail (core passes no opts at
all). One line upstream: `Mailer.deliver_email(email, skip_queue: true)`.

**Confidence:** 97/100 (call site and queue decision path both read directly; not executed
against a live relay)

### 2. [BUG - HIGH] A queued send loses an explicitly chosen integration and silently switches transport — MITIGATED (documented; real fix needs a core opt)

**File:** `lib/phoenix_kit/modules/emails/queue.ex` (moduledoc), `send_job.ex:53`

Core offers the message to the queue from inside **both** delivery paths, including
`Mailer.deliver_via_integration(email, integration_uuid, opts)` — but the opts it hands the
provider carry only `:provider` (`mailer.ex:361`, a `put_new` for log attribution), never the
uuid. `SendJob` therefore re-sends through `PhoenixKit.Mailer.deliver_email/2`, which resolves
the **default** integration. When the original call named a non-default connection, the queued
message leaves through a different relay than the caller asked for, with nothing logged about
the substitution.

This is not hypothetical. `phoenix_kit_newsletters`:

```elixir
# lib/phoenix_kit/newsletters/workers/delivery_worker.ex:610-627
defp deliver_profile_email(profile, ...) do
  ... |> PhoenixKit.Mailer.deliver_via_integration(profile.integration_uuid)
end
```

With this queue engaged, every attachment-free profile-routed broadcast is queued and then
re-sent through the default transport — wrong From-relay reputation, wrong SES configuration
set, wrong Brevo account. Secondarily, the newsletter worker sees `{:ok, %{id: ref, queued: true}}`
and records `ref` (the log uuid) as if it were a provider message id, while its own pacing and
per-recipient result tracking now describe enqueueing rather than delivery.

**Fix applied:** documented the constraint where a caller will look for it — the `Queue`
moduledoc and `AGENTS.md` — with the interim remedy: callers that pick their own transport must
pass `queue: false` (the gate already honours it). Not fixed in code because a correct fix is
not available inside this package: core must carry `integration_uuid` into the opts it offers,
`serialize_opts/1` must allowlist it, and `SendJob` must re-dispatch via
`deliver_via_integration/3` when present. Guessing from the `:provider` string alone is wrong
whenever a host has two connections with the same provider.

**Confidence:** 93/100 (both call sites and the opts core passes read directly; the newsletter
consequence is inferred from the code path, not observed on a live send)

### 3. [BUG - MEDIUM] A raise in the queued send leaves the log row stuck at "queued" forever — FIXED

**File:** `lib/phoenix_kit/modules/emails/send_job.ex:46-100`

The `{:error, _}` branch is safe: core's `handle_after_send/2` already ran inside
`deliver_email/2` and moved the row to `failed`. A **raise** does not reach that hook — an
adapter that throws instead of returning `{:error, _}`, a pool checkout timeout, an encoder
blowing up on a body — so the row is untouched and still carries the schema default,
`"queued"`. Oban retries, and on the fifth attempt discards the job; from then on nothing will
ever close that row. The card's "Today: … N queued" then counts a message that will never be
sent, which is the same silent state the card exists to eliminate.

Fixed by closing the row on the last attempt only, and reraising so Oban's own recording,
backoff and discard are untouched:

```elixir
rescue
  error ->
    if last_attempt?(job), do: fail_log(args, Exception.message(error))
    reraise error, __STACKTRACE__
end
```

`fail_log/2` now reads the log uuid out of the job args rather than off the rebuilt email, so
it also works when the raise came from `deserialize/1` itself and there is no email to read.

**Confidence:** 88/100 (the gap is certain from the code; how often adapters raise rather than
return `{:error, _}` is adapter-dependent)

### 4. [IMPROVEMENT - HIGH] A default-on queue with no off switch, and two dead setters — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/email_tracking.{ex,html.heex}`

`email_queue_enabled` defaults to **true**, so upgrading this package plus core changes how
every eligible outgoing message is sent for any host that has (or later adds) an `:emails` Oban
queue. The status card reported the queue's two settings read-only, and `Queue.set_enabled/1`
and `Queue.set_auth_mail_enabled/1` had no caller anywhere in the repo — the only way to turn
the queue off was editing the settings table by hand.

Fixed by wiring the existing setters to two checkboxes in the same section as the card
("Queue Outgoing Emails", and "Queue Authentication Emails Too" shown when the first is on),
both refreshing the status card through the existing `refresh_status/1`.

### 5. [BUG - MEDIUM] The "no :emails Oban queue" warning contradicted the row below it — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/settings_sections/email_tracking.html.heex:23`

The alert fired on `@status.queue.enabled? and not @status.queue.oban_queue_configured?`, which
ignores `email_enabled`. With the whole email system disabled the card printed
"The queue is on, but this application has no :emails Oban queue…" directly above a Queue row
reading "Off (system disabled)". Now gated on `@status.queue.status == :no_oban_queue`, the one
state that actually means "on, and cannot run" — `Queue.status/0` already computes exactly that.

### 6. [NITPICK] An unnamed default integration rendered a blank "Sending through" — FIXED

**File:** `lib/phoenix_kit/modules/emails/status.ex:93`

`Integrations.get_integration_by_uuid/1` defaults a missing name to `""`, which is truthy, so
`@status.transport.name || gettext("Default integration")` in the template rendered nothing at
all instead of the fallback label. `Status` now normalizes blank to `nil`.

### 7. [BUG - MEDIUM] `mix precommit` failed on the merged branch (three dialyzer errors) — FIXED

**Files:** `lib/phoenix_kit/modules/emails/queue.ex`, `send_job.ex`, `status.ex`

Verified by stashing my changes and running the gate on `cfb8f62` as merged: `mix dialyzer`
reported three errors, so the project's own release gate (`mix precommit` = compile
`--warnings-as-errors` + credo `--strict` + dialyzer) did not pass — which per `AGENTS.md`
step 3 blocks a release.

1. `queue.ex` — `defp log_uuid(_email), do: nil` is unreachable: `Swoosh.Email`'s `headers` is
   always a map, so the guarded first clause covers the type (`pattern_match_cov`). Collapsed to
   one clause.
2. `send_job.ex:88` — `Map.get(email.headers || %{}, …)`: `map() === nil` can never succeed
   (`guard_fail`). Removed as part of finding #3 (the uuid now comes from the job args).
3. `status.ex` — `is_binary(email) and Regex.match?(@sender_regex, email)`: core's
   `get_from_email/0` is typed as returning a string, so the `and`'s false branch is proven
   unreachable (`pattern_match`, reported against line 1 because `and` is generated code).
   Rewritten as `Regex.match?(@sender_regex, to_string(email))`, which keeps the nil-safety the
   guard was there for (a host really can configure `from_email: nil`; `to_string(nil)` is `""`,
   which fails the regex — the right verdict) without a branch dialyzer can prove dead.
   `logging_state/2`'s `false`/`true` literal clauses were rewritten as a `cond` for the same
   reason.

Gate after the fixes: format clean, compile with `--warnings-as-errors` clean, credo `--strict`
"found no issues", dialyzer "Total errors: 0", `mix test` 46 tests / 0 failures.

### 8. [OBSERVATION] Queued message bodies live in `oban_jobs.args`, outside this module's retention rules

**File:** `lib/phoenix_kit/modules/emails/queue.ex:192` (`serialize/1`)

`email_save_body` and `email_retention_days` govern this module's own tables. A queued message
carries recipients, subject and both bodies in its job args until the Oban row is pruned — so a
host that turned body storage *off* for privacy reasons still has full bodies in `oban_jobs`,
retained by whatever `Oban.Plugins.Pruner` policy it happens to have. Correct given the design
(the worker has to send *something*, and with `save_body` off the log row is not a carrier), but
it is a privacy surface this package's own "Data Privacy Notice" does not cover. Documented in
the `serialize/1` docstring as a warning admonition rather than changed.

### 9. [OBSERVATION] `Status.summary/0` runs on every parent render, and decrypts credentials to render a label

**File:** `lib/phoenix_kit/modules/emails/status.ex:47`, `web/settings_sections/email_tracking.ex:27`

`update/2` is invoked on every render of the parent LiveView, not only on mount — so an event in
*any* section of the Email Sending settings page costs this card two aggregate queries
(`job_counts/0`, `today_counts/0`) plus `Integrations.connected?/1` and
`get_integration_by_uuid/1`, the latter of which **decrypts the connection's stored credentials**
just to read its name. Settings reads themselves are cache-backed, so those are cheap.

Left as-is: the freshness trade is deliberate and documented in the component, and this is an
admin-only page. The piece worth revisiting is the credential decryption — a name-only lookup
would avoid touching secrets on every keystroke-blur.

### 10. [OBSERVATION] The `:emails` queue name is spelled in two places

`SendJob`'s `queue: :emails` and `Status.job_counts/0`'s `where j.queue == "emails"`. If the
worker's queue is ever renamed, the card silently reports zeros — one of the two lists this
feature has to keep in sync (the other, `serialize_opts/1` vs `deserialize_opts/1`, is already
covered by a test).

### 11. [OBSERVATION] The card's "queued" count is a log status, not a queue depth

`today.queued` counts log rows still at status `"queued"`, which includes rows an *inline* send
never closed out (a crash between interception and after-send). The genuine queue depth is the
`pending / executing / retryable` trio from `job_counts/0`. Not wrong, but the two numbers can
disagree and an operator will read them as the same thing.

## What Was Done Well

- **Every decline path is `:continue`.** `queue?/2`'s six gates, an `{:error, changeset}` from
  `Oban.insert/1`, a raise, and a DBConnection `exit` all fall through to an inline send. The
  queue cannot swallow mail; the worst case is that it never engages. The `rescue`/`catch` pair
  is the detail most implementations get wrong — `Oban.insert/1` only *returns* an error tuple
  for changeset failures, and raises for everything else.
- **`runnable?/0` is load-bearing, not diagnostic.** Refusing to enqueue when the host declared
  no `:emails` queue is what stops the feature from being a silent mail-swallower on a
  fresh install, and the "shape we don't understand reads as not-runnable" direction is the
  safe one. Locked in by a test.
- **The tracking header carries the log id across the hop**, and the interceptor's
  `already_tracked?` check plus core's `already_intercepted: true` are belt *and* braces — so a
  queued message gets one log row, not two, and the row it gets is the one the after-send hook
  updates. I verified the SES configuration set and message tags travel as *headers*, which
  `serialize/1` preserves in full: queued mail keeps its SES event tracking. This was the most
  plausible silent-data-loss candidate in the diff and it is handled.
- **`Log.email_format_regex/0`** — the card warns using the schema's own rule instead of a
  second copy, so the warning cannot drift from the validation that causes the failure.
- **Honest, load-bearing comments.** The `@impl`-on-an-optional-callback trade-off, the
  at-least-once caveat with the reason auth mail is excluded, and the "a stale card is worse
  than none" note that explains why `refresh_status/1` is called from every event — each
  documents a decision a future reader would otherwise reverse by accident.
- **The blocklist-at-dequeue path** is right: `{:cancel, :recipient_blocked}` rather than five
  retries against a permanent failure, and the log row is closed out with a readable sentence.

## Verdict

**Approved with fixes.** The design is sound and the failure-direction discipline is better
than most queue implementations — nothing in this diff can drop a message. The two HIGH
findings are both integration-boundary problems rather than defects in this code: core's own
test-send button (#1) and the transport identity that core does not pass along (#2). Both need
one-line-to-small changes in `phoenix_kit`, and until #2 lands, `phoenix_kit_newsletters` should
pass `queue: false` on its profile-routed sends — that is the only known caller affected today,
and it is a real misrouting, not a theoretical one. Findings #3–#7 are fixed here, with the
stuck-log-row rescue being the one that mattered.

## Follow-ups for other repos

1. `phoenix_kit` — `email_sending.ex:137`: pass `skip_queue: true` on the settings-page test send.
2. `phoenix_kit` — `mailer.ex:361`: carry `integration_uuid` into the opts offered to
   `maybe_enqueue/2`; then this package can allowlist it and re-dispatch via
   `deliver_via_integration/3`.
3. `phoenix_kit_newsletters` — `delivery_worker.ex:627`: pass `queue: false` until (2) lands.
