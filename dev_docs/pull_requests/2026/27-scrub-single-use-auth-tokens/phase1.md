# Phase 1 Review — phoenix_kit_emails #27

**Title:** Scrub single-use auth tokens out of the email log  
**Author:** Tymofii Shapovalov (timujinne)  
**Created:** 2026-08-07T09:54 UTC  
**Reviewer:** Pincer  
**Date:** 2026-08-07

---

## Scope

3 files: 1 modified, 1 new module, 1 new test file. No migrations, no version bump, no dependency changes.

## Files Changed

| File | Nature |
|------|--------|
| `lib/phoenix_kit/modules/emails/interceptor.ex` | Pipes body through `SecretScrubber.scrub/1` before slicing and before storing full body |
| `lib/phoenix_kit/modules/emails/secret_scrubber.ex` | New — regex-based token scrubber |
| `test/phoenix_kit/modules/emails/secret_scrubber_test.exs` | New — unit tests for scrubber |

## Red Flag Check

- **Unexpected files:** None
- **Build artifacts / swap / crash files:** None
- **Secrets or credentials:** None
- **Suspicious dependency changes:** None (mix.exs not touched)
- **Unrelated changes:** None

## What This Fixes

PhoenixKit stores only a SHA-256 hash of every emailed token, so the database itself cannot be reversed to recover one. But the email log stored the message body — including the full reset/confirm/magic-link URL. Any holder of the `emails` permission (Admin by default) could request a reset for any account from the public forgot-password page, then read the resulting link from `/admin/emails`, bypassing the target's mailbox entirely.

`SecretScrubber.scrub/1` is a regex-based allowlist that:
- Matches token-bearing URL path segments by segment NAME (not full path) — handles locale prefixes (`/et/users/reset-password/…`) and host-app route prefixes correctly
- Matches `?token=`, `?t=`, `?code=` query parameters
- Applies BEFORE the 1000-character slice (correct — a token straddling the slice boundary would escape a post-slice scrub)
- Applies to both preview and full-body paths
- Passes non-binary values through (nil-safe for pipeline use)
- Leaves the link structure intact (log still shows which mail was sent and where it pointed)

## Assessment

Small, focused, correctly placed. The scrub-before-slice ordering comment is explicit and correct. Pattern matching on segment names rather than full paths is the right call given locale-prefixed and host-prefix routes. Tests cover: reset, confirm, magic-link, verify, finish, query params, HTML bodies with multiple links, ordinary prose untouched, short segments not misidentified as tokens, nil pass-through.

No concerns.

## Verdict

✅ **RECOMMEND MERGE** — no blockers, no red flags.
