# PRs #32 + #33 — Multi-account AWS SES delivery event tracking, and its review follow-ups

**Reviewed:** 2026-08-13 · **Author:** @timujinne · **Verdict:** both merged
unchanged. Reviewed together because #33 is branched off #32 and only makes
sense against it.

## Summary

#32 transplants the proven Brevo multi-account pattern onto AWS SES: per-account
credentials and tracking config, an SQS polling job that loops accounts, a
module-owned migration chain adding `phoenix_kit_email_logs.integration_uuid`
for attribution, and per-account configuration-set resolution at send time. #33
is the follow-up batch filed during its review — i18n repairs, an atomic enable
path, daisyUI 5 form idiom, and a load-independent timing test.

## The migration is clean against core

This is the check that matters most here, because the module writes to a table
**core owns** (`phoenix_kit_email_logs` is created by core's chain, not this
module's). This workspace's rule is that a module must not create or own what
core ships — `phoenix_kit_legal` shipped in exactly that broken state until
0.3.0.

Verified directly against core's manifest: `PhoenixKit.Migrations.ExpectedSchema`
declares 34 columns on `phoenix_kit_email_logs`, and **`integration_uuid` is not
among them**. (Core does own `phoenix_kit_email_send_profiles.integration_uuid`
— a different table, and an easy thing to mistake for a collision.) So V01 adds
a genuinely new, nullable column to a core table rather than re-declaring
anything, and the PR's own constraints — additive-only, `down/1` never drops,
no emitted statement contains `DROP` (with a test asserting it) — keep it from
being able to damage a table it does not own.

## The bug this exists to prevent

Worth recording, because it is the sort that is invisible until it costs a
customer their delivery data: SES publishes events to the configuration set
named on the *send*, and the log field was being overwritten by the global
configuration set. With two accounts, sending through account B stamped with
account A's configuration set silently kills event publishing — no error, events
simply never arrive. Resolving the configuration set per account at send time
(global only as fallback) is the fix, and it is the core justification for the
whole PR rather than a detail of it.

The single-account inheritance rule is equally well-judged: the global queue is
inherited only by the explicitly selected `emails_aws_integration_uuid` **or** a
sole active account, so two unattributed accounts never end up polling one queue
with each other's credentials.

## #33's findings are all real, and two are the good kind

- **The fuzzy-translation bug is the most instructive.** `gettext.extract --merge`
  fuzzy-matched three strings onto a similar-looking msgid and flagged them
  fuzzy; gettext ignores fuzzy entries, so the UI showed another setting's
  wording. The worst told an operator that a failed *send-queue update* was about
  saving *email headers* — a message that actively misdirects debugging. This is
  the same class `phoenix_kit_billing` #20 and `phoenix_kit_document_creator` #37
  both declined to bulk-fix on the same day, for the same reason: the matcher's
  output cannot be trusted unreviewed.
- **The daisyUI 5 finding is not cosmetic.** `form-control`, `label-text` and
  `label-text-alt` do not exist in daisyUI 5 — they are not deprecated, they
  match nothing. Labels were being rendered by the one live `.label` rule, which
  dims to 60% opacity, so every field label in these two files looked
  deliberately de-emphasised. Worth noting the PR says **nine other files in this
  package still carry the dead v4 classes**; that is a real remaining defect,
  just not this PR's.
- **Replacing wall-clock with reductions in the linearity test** is the right
  instrument. A large run is preempted more often than a small one, so the old
  test measured scheduler contention and called it complexity — it would go red
  on a loaded CI box and green on a quiet one, which is worse than no test.

## The atomicity fix, and the asymmetry it exposes

Enabling polling wrote the eligibility flag, then the polling flag, then inserted
the first job. A failure in step two or three left the eligibility flag flipped
with polling off, and the panel reported failure without saying what it had
already changed — the operator's mental model and the stored state diverge
silently. One transaction is correct.

The part I'd have questioned and which #33 answers well: disabling deliberately
**does not** clear the eligibility flag, because that same flag gates the SNS
webhook path, which polls nothing. Making that argument in the `EventTracker`
docs rather than leaving it as an apparent inconsistency is the right resolution
— the asymmetry is intentional and now says so.

## Known limitations — accepted, and correctly flagged

- **~49 empty `ru`/`et` translations inherited from #32.** English shows through
  rather than anything wrong appearing, which is the safe failure, but it is a
  visible gap in two shipped locales.
- **The attribution gap:** explicit sends through a non-default connection of the
  same provider kind are not stamped. Documented in code, closes with a one-line
  core change. Narrow and honestly described.
- **Nine files still on dead daisyUI v4 classes** (above).

None of these blocks the release; all three are worth a follow-up pass, and the
translations gap is the one users will see first.
