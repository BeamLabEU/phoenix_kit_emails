# PR #29 — Update phoenix_kit requirement to >= 1.7.231 and < 3.0.0

**Reviewed:** 2026-08-10 · **Author:** timujinne · **Verdict:** merged, with the
pin decision overridden on `main`. Released in **0.2.0**.

## What it proposed, and what landed

Widen the core requirement so 1.8.x and 2.x both resolve. The diagnosis is
correct and matches core's own 2.0.0 CHANGELOG: `~> 1.7.231` expands to
`>= 1.7.231 and < 1.8.0`, so a host on `{:phoenix_kit, "~> 2.0"}` plus this
module is an unsolvable dependency set — `mix deps.get` fails outright.

The umbrella-wide decision for this sweep is a **2.0-only `~> 2.0`** rather than
a range spanning both majors, so `main` carries `{:phoenix_kit, "~> 2.0"}`.
Requiring 2.0 rather than merely tolerating it is the point: this module is only
verified against the squashed-migration baseline, and the resolver should say so.

## What was kept

The valuable part of this PR is not the version string, it is the comment block
around it, which records *which core API* each historical floor rests on:
1.7.231 for `PhoenixKitWeb.Live.UrlState` (`use`d by `web/blocklist.ex`),
1.7.217 for the optional `maybe_enqueue/2` provider callback the send queue
hangs off, 1.7.190 for `email_settings_sections/0`. That is exactly what a
future raise needs, and the PR's framing of why a stale floor is invisible —
the compile error surfaces in the *consumer's* build, never in this repo, whose
own lockfile always sits well above the floor — is worth keeping verbatim.

Those floors are now historical (2.x is above all of them), and the comment says
so rather than deleting them. The re-narrowing warning is retargeted at the trap
that now applies: keep it a two-segment `~> 2.0`, because `~> 2.0.x` expands to
`< 2.1.0` and reproduces the identical failure against core 2.1 that `~> 1.7.231`
had against core 2.0.0 — the very thing this PR was opened to fix.
