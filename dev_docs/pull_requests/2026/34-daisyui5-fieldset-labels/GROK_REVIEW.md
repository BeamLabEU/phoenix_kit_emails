# Code Review: PR #34 — emails: finish the daisyUI 5 conversion

**Reviewed:** 2026-08-14
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/34
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a376e515f9d03584d85d5bce7f40f7ebb36e700f (merge)
**Status:** Merged; post-merge fixes on main

## Summary

Markup-only follow-up to 71ad0e3. Converts the six templates the class
rename left on `<div class="fieldset">` + `<label class="label">` to real
`<fieldset>` / `<legend>`, adds `aria-label` on each visible control
(legend names the group, not the field), binds the four modal validation
messages with `aria-describedby` / `aria-invalid`, replaces the last
`input-group` with v5's `.input` label + `.label` suffix, and fixes two
invalid `<div>`-in-`<span>` toggle rows. Gettext catalogues were
re-extracted; the only msgid removal is the already-replaced
`"AWS setup failed: %{reason}"`.

The structural conversion is correct and matches the settings-section
reference. Bindings, names, and msgids were preserved. The review-round
commit that dropped `fieldset-label` from error text (it hard-sets 60%
opacity and fights `text-error`) is the right call.

## Issues Found

### 1. [BUG - HIGH] Retention blur resubmitted the previous assign — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/email_tracking.html.heex`,
`lib/phoenix_kit/modules/emails/web/email_tracking.ex`

The PR rewrote this input and claimed every `phx-*` binding was unchanged.
The unchanged binding was the bug. The handler matches
`%{"retention_days" => value}`, and the template supplied that key from
`phx-value-retention_days={assigns[:email_tracking_retention_days]}` —
the number already stored, not the number in the field. LiveView's
`phx-blur` payload puts the typed value under `"value"`. Changing 90 to
42 and blurring wrote 90 again.

The sibling settings section already does this correctly:
`name="retention_days"` and
`Map.get(params, "retention_days") || Map.get(params, "value")`.

**Fix:** named the input, dropped the stale `phx-value`, mirrored the
settings handler. Locked in by
`test/phoenix_kit/modules/emails/web/email_tracking_test.exs`.

**Note:** `Web.EmailTracking` is not in `admin_tabs/0` (settings live on
the core Email Sending page now). The page is still a compiled LiveView
and still the only UI that writes `email_ses_events` directly, so the
wiring is worth having right. See observation #6.

**Confidence:** 92/100

### 2. [BUG - MEDIUM] `btn-group` was not the last leftover v4 class — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.html.heex`

The PR said `input-group` was the last daisyUI 4 class in the module.
`btn-group` is in the same removal list (`btn-group` / `input-group`
were deprecated in 2023 and have no rule in v5). The HTML/Text preview
toggle on the template editor was still `btn-group`, so the pair no
longer shared a border.

**Fix:** `join` + `join-item`, matching the pagination already on
blocklist. File-scan test refuses `btn-group` (and the other dead v4
form classes) in any class attribute.

**Confidence:** 98/100

### 3. [BUG - MEDIUM] Template-editor field errors were still proximity-only — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.html.heex`

The author's own review-round commit said an inconsistency is worse than
the original uniform gap, and wired the test-recipient error the same
way as the emails / clone dialogs. The eight changeset errors on the
editor itself (name, display name, slug, category, status, description,
subject, both bodies) were left as bare `<div class="text-sm text-error">`
with no `id`, no `aria-invalid`, no `aria-describedby`.

**Fix:** same binding as the modals. Hidden per-locale inputs stay
unlabelled, as the PR intended.

**Confidence:** 90/100

### 4. [BUG - LOW] Import CSV textarea shipped with leading whitespace — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/blocklist.html.heex`

The PR added `aria-label` to this tag and left the indented blank
between `>` and `</textarea>`. That whitespace is the field's value.
HTML5 `required` treats it as filled; the importer trims and reports
"Successfully imported 0 blocked emails".

**Fix:** empty `<textarea …></textarea>`.

**Confidence:** 95/100

### 5. [IMPROVEMENT - MEDIUM] Search and variable-description fields still had no accessible name — FIXED

**Files:** `emails.html.heex`, `templates.html.heex`, `blocklist.html.heex`,
`template_editor.html.heex`

The PR's stated reason for `aria-label` on every field is that a legend
names the group. The toolbar search inputs have only a placeholder (not
a name), and the editor's variable-description inputs sat next to
`{{name}}` with no association. Same class of gap the PR set out to
close.

**Fix:** reused existing search msgids as `aria-label`; `aria-labelledby`
from the variable name span. No new gettext strings.

**Confidence:** 85/100

### 6. [OBSERVATION] Standalone `Web.EmailTracking` is not routed

**Files:** `emails.ex` `admin_tabs/0`, `event_tracker.ex`,
`sqs_polling_manager.ex`

`admin_tabs/0` does not register `Web.EmailTracking`.
`settings_tabs/0` is empty. Tracking settings render through
`email_settings_sections/0` → `SettingsSections.EmailTracking`.
`EventTracker` and `SQSPollingManager` still document the
`email_ses_events` toggle as living on `Web.EmailTracking`, and that
toggle exists only there. Enabling SES polling asserts the flag;
nothing in the live settings UI clears it.

Left alone — that is a product/routing question, not a markup defect,
and more PRs are inbound. Recorded so it is not rediscovered as a
surprise.

**Confidence:** 88/100

### 7. [NITPICK] Stale "fieldset-label" comments on error wiring — FIXED

The review-round commit removed `fieldset-label` from error text
(cascade fight with `text-error`) but left comments describing the
errors as `fieldset-label`. Comments updated to match the markup.

**Confidence:** 100/100

## What Was Done Well

- Matching each opening tag to the `</div>` at the same indent is the
  right way to convert this; no block boundary moved.
- Reusing existing msgids for `aria-label` kept
  `gettext.extract --check-up-to-date` clean and avoided the fuzzy-match
  trap this repo has already hit.
- Dropping `fieldset-label` from errors after checking the shipped v5
  bundle is exactly the kind of cascade check this conversion needs.
- The settings-section reference (`w-32` on unit suffixes because
  `.fieldset` is a grid, helper text as a paragraph under the field)
  is a good model; the standalone retention control follows it now.
- Catalogue re-extract with `--merge` and a one-line dead-msgid removal
  is the right gettext hygiene.

## Verdict

Approved with fixes — the conversion is the right job and the six
templates are structurally sound. The retention blur, leftover
`btn-group`, and unbound editor errors were real gaps in a PR that
claimed the module was finished. Those, the CSV textarea, and the
unnamed search/variable fields are fixed on main; the orphaned
`Web.EmailTracking` route is documented, not removed.
