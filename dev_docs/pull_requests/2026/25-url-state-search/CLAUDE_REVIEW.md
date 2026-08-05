# Code Review: PR #25 — Put the blocklist search, filters, sort and page in the URL

**Reviewed:** 2026-08-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/25
**Author:** Timujeen (timujinne)
**Head SHA:** 6b0722423d342deaa4030b6d33a69194bc1957a1
**Merge SHA:** ab8af68ef5ce3e0dd5516561eccf2695b158a5d7
**Status:** Merged

## Summary

Adopts `PhoenixKitWeb.Live.UrlState` in the Blocklist LiveView so that
`search_term`, `reason_filter`, `status_filter`, `sort_by`, `sort_dir` and
`page` live in the query string instead of in mount-seeded assigns. Six
`handle_event/3` clauses stop calling `assign/2 |> load_blocklist_data/1` and
push URL state instead; the single load now happens in `handle_url_state/2`,
which UrlState calls after mount and on every query-string change.

Net effect: the blocklist is a shareable, bookmarkable, reload-proof address,
and the Back button walks the filters instead of leaving the page.

## Issues Found

### 1. [BUG - HIGH] An out-of-range `?page=` renders one button per skipped page — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/blocklist.ex` lines 379–396
(`load_blocklist_data/1`), `blocklist.html.heex` line 519

Before this PR, `:page` could only be set by the `change_page` event, and the
template only ever offered page numbers inside `1..@total_pages`. Putting
`page` in the URL removes that guarantee: any value the decoder accepts now
reaches the template directly, and `UrlState` accepts `1..1_000_000` (the
`min: 1` in the spec plus the module's default integer ceiling).

`load_blocklist_data/1` computed `total_pages` from the row count but never
reconciled it with `@page`, so the pagination window

```elixir
for page_num <- max(1, @page - 2)..min(@total_pages, @page + 2) do
```

inverts. With `?page=900` on a two-page list that is `898..2`, which Elixir
builds as a **descending** range with step `-1` — 897 elements, i.e. 897
rendered `<button>` nodes in reverse order. `?page=1000000` on the same list
yields `999998..2//-1`: **999,997 buttons** from a single crafted or stale
link, plus a `Range.new/2` step deprecation warning per render.

Verified directly:

```
$ elixir -e 'IO.inspect(max(1, 999-2)..min(2, 999+2) |> Enum.count())'
warning: Range.new/2 and first..last default to a step of -1 when last < first.
996
```

The `@total_pages > 1` guard does not help — it is true whenever there is more
than one page, which is exactly the case that inverts.

**Fix applied.** `load_blocklist_data/1` now counts first, derives
`total_pages` with a floor of 1, and clamps `:page` before running the list
query, so the offset stays meaningful and the window can no longer invert:

```elixir
total_blocked = count_blocked_emails(build_filters(socket.assigns))
total_pages = max(ceil(total_blocked / socket.assigns.per_page), 1)
socket = assign(socket, :page, clamp_page(socket.assigns.page, total_pages))
blocked_emails = load_blocked_emails(build_filters(socket.assigns))
```

Assigning a declared param directly is explicitly supported by `UrlState` —
`current_state/2` reads its merge base back from the assigns, so the next
patch carries the corrected page rather than resurrecting the URL's value.
The template's range also gained an explicit `//1` step as a second line of
defence, and `clamp_page/2` is `@doc false`-public so the regression is pinned
by a test that needs no database.

**Confidence:** 95/100

### 2. [BUG - MEDIUM] Sort-column whitelist duplicated, and drifting is silent — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/blocklist.ex` lines 56–61 and 434

The PR introduced a second copy of the sortable-column list: the UrlState spec
carried an inline `in: [:email, :reason, :inserted_at, :expires_at]` while
`@sort_fields` (used by `validate_sort_by/1`) held the same four atoms 380
lines further down. A third copy lives in the `field in [...]` guard of
`RateLimiter.list_blocklist/1`.

This is the exact failure mode the PR's own follow-up commit (6b07224) had to
fix for `reason_filter`: a value the header offers but the URL whitelist
rejects falls back to the default, so the resulting URL is unchanged, the
callback never fires, and the click has **no visible effect** — no error
anywhere. Adding a sortable column to `@sort_fields` and forgetting the spec
reproduces it exactly.

**Fix applied.** `@sort_fields` is hoisted above the `use
PhoenixKitWeb.Live.UrlState` block and referenced by the spec, so the decoder
and `validate_sort_by/1` cannot disagree. A test pins the list against the
columns `list_blocklist/1` can actually order by, which is the one copy that
cannot be deduplicated (it is an inline guard in another module).

**Confidence:** 90/100

### 3. [OBSERVATION] The reason dropdown only offers reasons of *active* blocks

**File:** `blocklist.html.heex` line 202, `rate_limiter.ex` lines 490–497

`reason_options` comes from `@statistics[:by_reason]`, whose query filters
`is_nil(b.expires_at) or b.expires_at > ^now`. So with **Include Expired**
selected, a reason carried only by expired rows is filterable via a
hand-written `?reason=` but is not offered in the dropdown.

Pre-existing (the statistics query never took the screen's filters into
account) and not a regression from this PR. Left as-is deliberately: making
the dropdown filter-aware means threading the status filter into
`get_blocklist_stats/0`, which is also used for the summary cards where the
active-only count is the correct number.

### 4. [OBSERVATION] Page links are events, not links

**File:** `blocklist.html.heex` lines 511–540

Pagination uses `phx-click="change_page"` on `<button>` elements. `UrlState`
documents `url_state_path/2` for precisely this case ("For links rather than
events (`<.pagination>`, `<.link patch=…>`), build the target with
`url_state_path/2`"). Since the PR's stated goal is a real, shareable address,
page 3 arguably deserves an `href` so it can be middle-clicked or opened in a
new tab.

Not fixed: it is a UI change beyond the PR's scope, `@url_path` plumbing would
need checking against the admin layout, and `emails.html.heex` uses a shared
`<.pagination>` component that would be the better place to solve it once for
every list screen. Recorded here so the limitation is on record.

### 5. [OBSERVATION] The first search replaces the entry that got you here

**File:** `blocklist.ex` line 154

`filter_search` pushes with `replace: true`, which is correct for a debounced
input — the alternative is one history entry per typing pause. The documented
trade-off is that the very first keystroke replaces the unfiltered
`/blocklist` entry, so Back from a search leaves the page rather than
returning to the unfiltered list. This matches `UrlState`'s guidance and the
PR's own comment; noted only so the behaviour is not later reported as a bug.

## What Was Done Well

- **The Iron Law is now respected.** `mount/3` previously ended in
  `|> load_blocklist_data()`, so every page load ran the list, count and
  statistics queries **twice** — once for the disconnected render, once for
  the WebSocket mount. Moving the load to `handle_url_state/2` puts it on the
  `handle_params` path where it belongs, and one code path now serves the
  first render, a shared link and the Back button alike.
- **The `@impl` trap was handled correctly.** The module annotates its
  callbacks, so the bare `handle_params/3` stub `__before_compile__` would
  have injected is a missing-`@impl` warning that `--warnings-as-errors`
  promotes to a compile error. The PR defines the annotated stub explicitly,
  and the comment above it explains why it exists — which is exactly what stops
  someone deleting it as dead code later.
- **The `reason_filter` reasoning is right and well documented.** Reasons are
  free-form (`hard_bounce` from the SQS processor, `complaint_spam` from the
  rate limiter, arbitrary strings from CSV import) and the dropdown is built
  from the data, so a fixed `in:` list would reject the screen's own options.
  Commit 6b07224 caught this before merge and the comment records why the
  whitelist must stay absent.
- **`cast: :atom` params carry `in:` lists**, so no atom is ever created from
  user input — the URL string is matched against pre-existing atoms.
- **The disabled-system path is safe.** When `Emails.enabled?/0` is false,
  `mount/3` returns a `push_navigate`d socket that never receives the
  `per_page` assign `load_blocklist_data/1` needs. Both
  `Channel.maybe_call_mount_handle_params/4` and
  `Static.mount_handle_params/4` short-circuit on `socket.redirected` before
  reaching `handle_params`, so the UrlState hook never fires and the callback
  never runs against the half-built socket. Confirmed against the vendored
  `phoenix_live_view` source rather than assumed.
- **Query building is parameterised throughout.** `search_term` and
  `reason_filter` are unbounded free-form strings straight out of the URL, but
  they reach Ecto as pinned parameters (`ilike(b.email, ^"%#{term}%")`,
  `b.reason == ^reason`), so widening the input surface introduces no
  injection risk.

## Verdict

**Approved with fixes.** The migration to `UrlState` is well judged, correctly
executed and unusually well commented — the comments explain *why* each
non-obvious choice was made, which is what makes them survive. The one real
defect is the class of bug this kind of PR invites: a value that used to be
constrained by the UI became attacker- and bookmark-controlled, and the
consumer downstream still assumed the old invariant. Fixed, with a test that
does not need a database.

## Changes Made Post-Merge

| File | Change |
|---|---|
| `lib/phoenix_kit/modules/emails/web/blocklist.ex` | Clamp `:page` to `total_pages` before querying; add `clamp_page/2`; hoist `@sort_fields` above the UrlState spec and reference it there |
| `lib/phoenix_kit/modules/emails/web/blocklist.html.heex` | Explicit `//1` step on the pagination window |
| `test/phoenix_kit_emails_test.exs` | New `"Blocklist URL state"` describe block: sort whitelist sync, `reason_filter` stays free-form, `clamp_page/2` keeps the window ascending and ≤ 5 wide, page bounds |
