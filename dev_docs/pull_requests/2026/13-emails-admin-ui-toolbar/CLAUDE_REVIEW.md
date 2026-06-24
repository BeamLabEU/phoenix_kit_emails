# Code Review: PR #13 — Rework Emails admin UI: shell header, table toolbar, template-based test send

**Reviewed:** 2026-06-24
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/13
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** aa96e87d955ae4ae2734223a23d16747ce36da07
**Merge commit:** ce8cd829cdaa8f7a99870c52cfeaa0f0e3b265ac
**Status:** Merged

## Summary

Admin-UI overhaul of the emails module (1781 +/1059 −, 19 files, almost entirely
LiveView + HEEx). Page titles/subtitles move into the admin shell top bar via
`page_title`/`page_subtitle` assigns; the four list pages (Emails, Templates,
Queue, Blocklist) gain a daisyUI table toolbar with dropdown filters, an inline
search with a clear `×`, clickable column-header sorting, body-row click-to-open,
and (Emails) a `draggable_list` column customizer with a working-copy +
Save/Default/Cancel flow. `Send Test` now renders and sends the seeded
`test_email` template and records `template_name` / `user_uuid` /
`source_module: "emails"` so Details shows the template, user, and module.

This was stacked on PR #12; with #12 already merged, the net diff is UI-only.

## Verdict

**Approved.** This is a careful, well-structured PR. I focused on the parts most
likely to harbor bugs (URL/event-driven sorting reaching SQL, queries in `mount`,
the row-click vs in-row-control conflict, and the new test-send plumbing) and each
one is implemented correctly. No must-fix bugs were found; the two hardening
items below (#2 column-id validation, #3 sort tiebreaker) were applied as
follow-ups by request. Gate is clean against **phoenix_kit 1.7.165**
(`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict` —
no issues).

## What I Verified (risk areas that are SAFE)

These are the spots that *looked* risky and were checked against the source of
truth — recording them so the next reviewer needn't re-derive:

- **Sort params → SQL is injection-safe and correctly synced.** `validate_sort_by/1`
  never calls `String.to_atom` on user input — it matches the incoming string
  against `Atom.to_string(field)` for each atom in a compile-time whitelist
  (`@sort_fields`), so no atom-table exhaustion and no arbitrary column reaches
  `order_by`. Cross-checked each LiveView whitelist against its context's
  `apply_ordering/2`:
  - Emails `[:sent_at, :to, :subject, :status, :template_name]` → all five are real
    `Log` columns; `Log.apply_ordering/2` uses `field(l, ^order_by)` with the
    matching `:order_by`/`:order_dir` keys.
  - Templates `[:name, :usage_count, :last_used_at, :inserted_at]` → matches
    `Templates.apply_ordering/2`'s own internal whitelist exactly, and the PR uses
    the right option key (`:order_direction`, which differs from Emails'
    `:order_dir` — and that difference is correct because the two contexts expect
    different keys).
  - Blocklist `[:email, :reason, :inserted_at, :expires_at]` → matches
    `RateLimiter.list_blocklist/1`'s internal whitelist and `:order_dir` key.

  Both Templates and Blocklist contexts *also* re-guard the field internally, so
  they are doubly safe; Emails relies on the LiveView whitelist, which is sound
  because every whitelisted atom is a real column.

- **Row-click vs in-row controls is correctly isolated.** Emails/Queue rows carry
  `phx-click="view_details"`. Emails uses the `table_row_menu` component, whose
  `RowMenu` JS hook calls `e.stopPropagation()` on the trigger and portals the
  menu `<ul>` to `<body>` while open — so neither opening the ⋮ menu nor clicking
  `sync_log`/`view_details` items bubbles to the row. Queue and Templates use
  *inline* controls and correctly wrap them in `onclick="event.stopPropagation()"`.
  (Emails' zero manual `stopPropagation` is therefore correct, not a regression.)

- **Column customizer preserves required columns.** The new `remove_column` handler
  dropped the old per-event `required` guard, but `TableColumns.update_user_table_columns/1`
  → `ensure_required_columns/1` re-adds `@required_columns ["to", "actions"]` on
  save, and the LiveView's `ensure_actions_column/1` keeps `actions` last — so a
  removed-then-saved required column is restored.

- **Template-based test send is fully wired.** `Templates.render_template/2` returns
  `%{subject:, html_body:, text_body:}` (so `rendered.subject` etc. are valid);
  `PhoenixKit.Mailer.deliver_email/2` threads `opts` into
  `intercept_before_send(email, opts)`; and the interceptor records
  `:template_name`, `:user_uuid`, and `:source_module` (as a message tag).
  `Scope.user_uuid/1` exists and handles the `user: nil` case.

- **Pagination preserves sort + filters.** Both Emails and Templates pass a `params`
  map (including `sort_by`/`sort_dir` and all filters) to `<.pagination>`, which
  merges them into each page link via `build_page_url/3`. Sorting/filtering is not
  lost when paging.

## Observations / Nitpicks (non-blocking)

### 1. [OBSERVATION] Pre-existing DB query in `mount` (Blocklist, Queue)
`Blocklist.mount/3` calls `load_blocklist_data/0` (and Queue similarly) directly in
`mount`, so the query runs twice (HTTP render + WebSocket connect). This is
**pre-existing** — PR #13 only adds `page_title`/`sort_*` assigns ahead of the
existing load — but it's worth a future pass to move the load into `handle_params`
(as Emails and Templates already do). Not introduced here.

### 2. [OBSERVATION - LOW] Column id input is not validated against `@available_columns` — FIXED
`update_table_columns` (`column_order` from a hidden input) and `add_column`
(`column_id`) accept arbitrary client-supplied strings and persist them. A crafted
payload could store an unknown column id; the table body's `for field <- @selected_columns`
loop renders a `—` cell for it while the header loop skips it (`if column do`),
producing a header/body cell-count mismatch for that admin's view. Admin-only and
self-inflicted, but filtering the incoming ids against the known
`available_columns` fields would harden it.

**Fix applied** (`web/emails.ex`): added `known_column_fields/1` and made
`save_and_close_column_modal/2` the single chokepoint that filters every persist
path against the available-column set (then keeps `actions` last); `add_column`
now ignores ids not in that set. Unknown ids can no longer be persisted.

### 3. [NITPICK] No tiebreaker for sorting on low-cardinality columns — FIXED
Sorting by `status` (or `subject`) has no secondary order key, so rows with equal
values can reorder between page loads / across pages. Adding a stable secondary
sort (e.g. `:sent_at desc` / `:uuid`) would make pagination deterministic.

**Fix applied:** added a `desc: <pk>.uuid` secondary sort to `apply_ordering/2` in
`log.ex`, `templates.ex`, and `rate_limiter.ex` (`list_blocklist/1`). All three
schemas use UUIDv7 PKs (time-ordered), and `:uuid` is in none of the sort
whitelists, so the tiebreaker never duplicates the primary key and makes paging
deterministic for the Emails, Templates, and Blocklist lists.

### 4. [NITPICK] `Templates.track_usage/1` runs before delivery in the test send
In `Provider.send_test_tracking_email/2`, usage is incremented before
`deliver_email/2`, so a failed test send still counts as a template use. Minor.

## What Was Done Well

- Sorting is implemented the safe way (whitelist of pre-existing atoms, no dynamic
  atom creation) and kept in sync with three different contexts including their
  differing option-key conventions — exactly the kind of "two lists drifting" trap
  that's easy to get wrong.
- The column customizer's working-copy pattern (`temp_selected_columns`, mutated by
  add/remove/reorder/reset, persisted only on Save, reset on Cancel) is clean and
  correctly seeded/cleared on open/close.
- Reusing PR #12's `update_log_row/2` for the new in-place `sync_log` row action,
  wrapped in a `rescue` that surfaces a flash instead of crashing the LiveView.
- Consistent use of `Routes.path/1` for prefix/locale-aware navigation and
  pagination base paths; `gettext` applied to the new titles/subtitles.
