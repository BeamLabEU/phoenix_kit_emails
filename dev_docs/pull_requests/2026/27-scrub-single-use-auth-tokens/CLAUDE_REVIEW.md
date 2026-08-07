# Code Review: PR #27 — Scrub single-use auth tokens out of the email log

**Reviewed:** 2026-08-07
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/27
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 7b792f7
**Status:** Merged

## Summary

Adds `PhoenixKit.Modules.Emails.SecretScrubber` and wires it into
`Interceptor.extract_body_preview/1` and `extract_body_full/2`, so single-use
auth tokens (password reset, confirmation, email change, magic link, magic-link
registration, organisation invitation) are replaced with `[REDACTED]` before the
body is written to `phoenix_kit_email_logs`.

The vulnerability is real and well-described: core stores only a SHA-256 hash of
every emailed token, so the raw token exists in exactly one place — the message.
Logging the body put it back in the database in plaintext, behind a permission
(`emails`) the Admin role holds by default. Anyone with that permission could
request a reset for any address on the public forgot-password page and read the
working link out of `/admin/emails`, never touching the target's mailbox.

Scrubbing on the way IN (not on the way out) is the right placement: the token
never reaches the row, so exports, backups and support dumps are covered by the
one control.

## Issues Found

### 1. [BUG - HIGH] The scrubber fails OPEN on slash-heavy bodies — FIXED

**File:** `lib/phoenix_kit/modules/emails/secret_scrubber.ex` lines 61–70 (as merged)

The URL pattern anchored on the scheme and reached the auth segment through two
overlapping lazy quantifiers:

```elixir
@token_url ~r/
  (https?:\/\/[^\s"'<>\)\]]*?\/                                  # lazy, crosses `/`
   (?:reset-password|confirm|confirm-email|magic-link|verify|finish|invitations?)
   (?:\/[^\s"'<>\/\)\]]+)*?\/)                                   # lazy, also crosses `/`
  ([A-Za-z0-9_\-=%.]{16,})
/x
```

Both the prefix and the middle group consume `/`-delimited segments, so for any
body containing repeated auth-segment names there is a quadratic number of ways
to split the path between them. Every start position re-explores that space.

Measured on the merged code (`String.replace/3`, body = `https://a.com/` +
`confirm/` × n, then a real reset link):

| n | body | time | token redacted? |
|---|---|---|---|
| 640 | 5 KB | 32 ms | yes |
| 2560 | 20 KB | 104 ms | **no — leaked** |
| 10240 | 82 KB | 105 ms | **no — leaked** |

Past roughly 20 KB, PCRE hits its internal backtracking limit. `String.replace/3`
does not raise or signal on that — it returns the subject **unchanged**. So the
body sails through with its token intact, `body_preview`/`body_full` are written
in plaintext, and the row looks scrubbed. A security control that silently
no-ops on hard input is worse than no control, because nothing downstream can
tell the difference.

Reachability is modest but not theoretical: the payload is ordinary text, and
apps routinely render user-supplied content (organisation names, newsletter
copy, submitted content) into mail that also carries auth links. The correctness
property — a scrubber that cannot quietly give up — is worth having regardless
of how hard the payload is to deliver.

**Fix applied.** Anchor on `/<auth-segment>/` instead of on `https?://…`, and
drop the intermediate-segment group, leaving no quantifier that spans path
separators:

```elixir
@token_url ~r/
  (\/
   (?:reset-password|confirm-email|confirm|magic-link|verify|finish|invitations?)
   \/)
  ([A-Za-z0-9_\-=%.]{16,})
/xi
```

Matching is now linear: the 82 KB case above drops from 105 ms (leaking) to
1.4 ms (redacted), and 327 KB takes 5.5 ms and still redacts.

Nothing is lost by dropping the intermediate group — every auth route core
emails puts the token immediately after the segment, and the locale
(`/et/users/reset-password/…`) and host-app (`/phoenix_kit/users/…`) prefixes it
was written for sit *before* the segment, not between. Dropping the scheme
anchor slightly widens coverage (a bare `/users/reset-password/<token>` path in
text is now caught too), which is the safe direction.

**Confidence:** 95/100 — measured directly, both before and after.

### 2. [BUG - MEDIUM] Path pattern was case-sensitive while the query pattern was not — FIXED

**File:** `lib/phoenix_kit/modules/emails/secret_scrubber.ex` line 70 (as merged)

`@token_query` carried `/i`, `@token_url` did not, so
`https://app.example.com/users/RESET-PASSWORD/<token>` leaked while
`?TOKEN=<token>` was caught. Core generates lowercase paths, so this is not
reachable through core's own mail — but the module is a library, the host app
supplies its own route prefix, and the asymmetry between the two patterns is
the kind of thing that reads as intentional later. Added `i` to the path
pattern; both are now case-insensitive.

**Confidence:** 90/100 — verified; low real-world impact.

### 3. [BUG - MEDIUM] The route enumeration test omitted the email-change route — FIXED

**File:** `test/phoenix_kit/modules/emails/secret_scrubber_test.exs` lines 23–35

The test enumerating auth routes covered `confirm`, `magic-link`, `verify` and
`finish` but not `confirm-email` — the one route in the whitelist whose name is
a *prefix collision* with another entry (`confirm`). In the merged pattern the
alternation listed `confirm` before `confirm-email`, so
`/dashboard/settings/confirm-email/<token>` only matched by backtracking out of
`confirm`. That worked, but it worked by accident and nothing pinned it.

`deliver_update_email_instructions/2` sends this route
(`integration.ex:618` registers `/dashboard/settings/confirm-email/:token`), so
it is a live 7-day single-use credential. Added it to the enumeration and
reordered the alternation to put `confirm-email` first.

**Confidence:** 100/100.

## Cross-check: does the whitelist match the real route set?

Enumerated every `:token` route core registers (`integration.ex`) against every
URL core actually emails (`user_notifier.ex`, `invitations.ex`, `magic_link.ex`,
`magic_link_registration.ex`):

| Emailed URL | Sender | Covered |
|---|---|---|
| `/users/reset-password/:token` | `deliver_reset_password_instructions/2` | ✅ path |
| `/users/confirm/:token` | `deliver_confirmation_instructions/2` | ✅ path |
| `/dashboard/settings/confirm-email/:token` | `deliver_update_email_instructions/2` | ✅ path (now tested) |
| `/users/magic-link/:token` | `magic_link.ex:253` | ✅ path |
| `/users/register/verify/:token` | `deliver_magic_link_registration/2` | ✅ path |
| `/users/register?invitation=<token>` | `deliver_organization_invitation/3` | ✅ query |

The whitelist is complete for emailed tokens. `deliver_new_login_alert/2` is the
only other notifier entry point and carries no token.

Three `:token` routes are *not* covered, all correctly so:

- `/users/qr-login/scan/:token` — rendered into an on-screen QR code
  (`qr_login.ex:140`), never emailed.
- `/users/register/complete/:token` — reached only by redirect from the verify
  LiveView (`magic_link_registration_verify.ex:18`), never emailed.
- `/file/:file_uuid/:variant/:token`, `/tiles/:token/…` — signed asset URLs, not
  auth credentials, and the token is not the final segment so the pattern shape
  could not cover them anyway.

## Issues NOT fixed

### 4. [OBSERVATION] Rows written before the upgrade still hold live tokens

Scrubbing is on the write path only. An install upgrading to this release keeps
every previously logged reset/confirm/invitation link in
`phoenix_kit_email_logs`, and the described attack works against those rows
until the tokens expire.

Deliberately not fixed. The exposure is bounded by core's own TTLs — reset 1
hour, magic link 15 minutes, confirm / email-change / invitation 7 days — so a
backfill is worth something for at most a week after upgrade. Against that, this
module owns no migrations (by design; `release_check` reports the missing
migration directory as expected), so a data migration would mean introducing
migration infrastructure for a one-week window, plus a full-table regex rewrite
over a table that can be very large. Operators who want the guarantee sooner
already have `email_retention_days` and the archiver.

Recorded here so the limitation is on the record rather than discovered.

### 5. [NITPICK] `extract_body_preview/1` was promoted from `defp` to `def` for a test

**File:** `lib/phoenix_kit/modules/emails/interceptor.ex` line 611

`@doc false` keeps it out of the docs, and the accompanying comment explains
exactly why (a test against `SecretScrubber.scrub/1` alone stays green while the
pipeline leaks — which is what happened when stripping ran first). Widening the
API surface for testability is a real cost, but the ordering bug it pins is
subtle and was actually hit during development. Left as is.

## What Was Done Well

- **The placement argument is the important one, and it is right.** Scrubbing on
  ingest rather than on render means exports, S3 archival, backups and support
  dumps are all covered by one control. Scrubbing in the LiveView would have
  covered exactly one reader.
- **The scrub-before-strip ordering is correct and pinned by a test at the real
  call site.** `strip_html_tags/1` rewrites every entity to a space, so an
  entity-encoded `&amp;token=` reaches a post-strip scrubber as ` token=` and
  can never match. `interceptor_scrub_order_test.exs` exercises
  `extract_body_preview/1` itself rather than the scrubber in isolation, which
  is the only way that class of bug stays caught.
- **Scrub-before-slice is also correct** and tested: a token straddling the
  1000-character boundary would otherwise escape.
- **Matching on segment names rather than whole paths** is the right call given
  host-chosen route prefixes and locale-prefixed twins, and the reasoning is
  written down.
- **The "deliberately NOT scrubbed" section on the send queue** is exactly the
  kind of thing that gets "fixed" into a production incident later —
  `Queue.serialize/1` args are the message in transit, and redacting there would
  mail users a `[REDACTED]` link. Documenting the retention trade-off around
  `email_queue_auth_mail` rather than pretending the scrubber solves it is
  honest.
- **The 16-character floor** is well-chosen and justified against the actual
  token shape (`Base.url_encode64/2` of 32+ random bytes), and the
  "short trailing segment is not a token" test pins it.
- Comments explain *why*, not *what*, throughout.

## Verdict

**Approved with fixes.** The vulnerability is real, the placement is right, and
the reasoning in the module is unusually good. Three defects found and fixed
post-merge, one of them significant: the pattern could silently fail open and
write a live token to the log while appearing to have scrubbed it. All fixes
are locked in by tests, including a linear-time regression test that would catch
a reintroduced backtracking blowup.
