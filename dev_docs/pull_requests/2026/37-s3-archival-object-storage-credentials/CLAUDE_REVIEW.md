# Code Review: PR #37 — S3 archival: accept object_storage connections, not only aws_ses

**Reviewed:** 2026-08-18
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/37
**Author:** Tymofii Shapovalov (timujinne)
**Merge commit:** 40e8c27 (+ pre-merge follow-up 8e13a83)
**Status:** Merged

## Summary

Archival's credential resolution (`Archiver.s3_request_config/0`) previously
read through `Emails.aws_ses_credentials/1`, which rejects any connection
whose `provider` isn't `"aws_ses"`. Core's `object_storage` provider — built
specifically for S3-compatible archival targets independent of an SES
sending connection — was silently rejected: pointing `email_s3_integration`
at one returned an empty credential map, and archival signed with nothing
while the settings page reported it as configured.

The PR adds `Emails.s3_archival_credentials/1`, a second getter that accepts
`["aws_ses", "object_storage"]`, kept deliberately separate from
`aws_ses_credentials/1` (a documented leak guard for the SEND path — an
`object_storage` connection has no business signing outgoing mail).
`Archiver.s3_request_config/0` now branches on `creds["provider"]`: `aws_ses`
keeps its existing blank-region-stays-blank behavior; `object_storage` builds
a host/region/endpoint config via a new `object_storage_config/1`, which
hand-ports core's not-yet-hex-released `Integrations.Validators.object_storage_config/1`
(endpoint scheme/slash stripping, China-partition host, blank-region default
to `"us-east-1"`) with a comment naming the exact collapse condition. The
settings picker (`email_tracking.ex`) now lists `object_storage` connections
too, labelled with a provider display name instead of the raw key.

Per the PR body, this already went through an independent two-round review
before merge; round 2's one blocking finding (probe-tuned `retries`/
`http_opts` carried into the actual upload path, making `object_storage`
archival less resilient to transient S3 errors than `aws_ses`) was fixed in
commit 8e13a83, folded into the branch before merge.

## Verification

- Confirmed the provider-allowlist split is real and correctly scoped:
  `aws_ses_credentials/1` → `fetch_credentials_for_providers(uuid,
  ["aws_ses"])`; `s3_archival_credentials/1` → same helper with
  `["aws_ses", "object_storage"]`; distinct cache keys
  (`{:credentials, uuid}` vs `{:s3_archival_credentials, uuid}`), so a
  lookup for one never poisons the other (`emails.ex:3106-3184`).
- Confirmed `s3_request_config/0` reads through the new getter (not the
  SEND-path one) and branches on `creds["provider"]`, with the `aws_ses`
  branch unchanged (blank region deliberately left blank) and a new
  `object_storage` branch (`archiver.ex:696-789`).
- Confirmed core (`deps/phoenix_kit`, pinned `~> 2.0`, currently 2.13.0 in
  `mix.lock`) does **not** yet ship `Integrations.Validators.object_storage_config/1`
  — grepped `deps/phoenix_kit/lib/phoenix_kit/integrations/`, no match — so
  the hand-ported duplicate in `archiver.ex` is still load-bearing, not
  leftover. `Providers.get("object_storage")` also isn't registered in this
  core version, confirming the picker's raw-key fallback
  (`provider_display_name/1`) is currently exercised, not dead code.
- Confirmed the settings picker (`email_tracking.ex:s3_connections/0`) now
  queries `["aws_ses", "object_storage"]` via
  `Integrations.load_all_connections/1` and labels each option with its
  provider's display name — matches what `s3_archival_credentials/1` accepts,
  so the picker can't offer a connection the getter would reject.
- Confirmed the post-merge fix (8e13a83) actually removed the probe-tuned
  `retries`/`http_opts` from `object_storage_config/1` — the upload path now
  falls through to ExAws's own defaults for both provider branches, per the
  round-2 review finding.
- Test coverage (`archiver_test.exs`) exercises: an `object_storage`
  connection signing with its own region, a custom `endpoint` (scheme/slash
  stripped) signing against it instead of AWS, the SEND-path leak guard
  rejecting an `object_storage` credential, and `aws_ses`'s own region key
  (`aws_region`) still working unshadowed.
- `mix precommit` (format, compile --warnings-as-errors, credo --strict,
  dialyzer): clean — 1577 mods/funs, no credo issues; dialyzer 2
  pre-existing gettext/Expo PLT skips only (baseline, unrelated).
- `MIX_ENV=test mix test --include integration`: 1 doctest, 467 tests, 0
  failures.

## Issues Found

None. The provider split is correctly scoped end to end (getter allowlist →
config branch → settings picker), the temporary core-duplication is real and
accurately commented with its own collapse condition, and the one blocking
issue from the PR's own pre-merge review round (probe-tuned retry settings
leaking into the upload path) was already fixed before merge.

## What Was Done Well

- Kept the SEND-path credential getter untouched and added a new one rather
  than widening its allowlist — a `object_storage` connection genuinely
  cannot sign outgoing mail, and conflating the two getters would have made
  that mistake reachable.
- The temporary core-duplication documents both *why* it exists (hex-pinned
  core predates the function) and the exact condition for deleting it later,
  instead of leaving a silent fork to drift.
- Test suite covers the actual failure mode the PR fixes (empty credentials
  from an `object_storage` connection) plus the edge cases most likely to
  regress silently (endpoint stripping, region key mismatch, the leak
  guard).

## Verdict

Approved — no changes required. Proceeding to release.
