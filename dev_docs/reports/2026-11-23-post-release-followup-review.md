# Follow-up review of the post-0.10.0 changes

**Reviewer:** Mistral Vibe
**Date:** 2026-11-23
**Base:** `4873e17` (HEAD at review time; last Hex release 0.10.0 tagged at `a3b67fd`)
**Scope:** every commit since the 0.10.0 tag — `491882e` (docs gate), `f78d844` + `4873e17` (mix.lock-only "lib upgrades", phoenix_kit 3.6.0 → 3.7.0), `6f06570` (the post-0.10.0 fix batch), `586cf10` (the review report).

## What was verified clean

- **Export routes/controller.** Core mounts module `generate/1` routes root-scoped (`integration.ex`: "Every module's `generate/1` currently emits root-scoped literal routes"), and `/emails/...` is not a reserved path, so the `locale: :none` in the new `Paths.export_*` helpers is required and correct. The four actions exist, the plug's `Scope.has_module_access?/2` + `Permissions.enabled_module_keys/0` calls match core 3.7.0's API and the same pattern core uses in `auth.ex`, and `:phoenix_kit_admin_only` assigns `phoenix_kit_current_scope` before the controller plug runs. `list_logs` applies `:limit` uncapped, so the 1M export limit really lifts the 50-row default; `build_export_filters` whitelists its params (no atom/order injection). `JSON.encode!/1` works on `Log`/`Event`/`EmailBlocklist` (all `@derive {JSON.Encoder, ...}`).
- **Event normalization.** `@ses_event_types` is a strict subset of the changeset's `validate_inclusion` list, so a normalized type can't be refused by the changeset (no poison loop via that path). `map_section/2` and the `get_in` timestamp reads match the webhook-hardening claims.
- **SQS placeholder gating.** `{:error, :email_log_not_found}` on a disabled placeholder log is consistent with the pre-existing behavior of every other event type, and `process_single_message` deliberately keeps errored messages (the `:system_disabled` comment documents that as intentional); delivery_delay/subscription now behave like the rest, not worse.
- **Interceptor.** The new `rescue` on `do_intercept_before_send/2` only guards logging — block/rate decisions are return values elsewhere, not raises here, so nothing is un-blocked by it. `past_send_status?/1` covers all post-delivery statuses used in the codebase; sampling is rolled once (interceptor, deterministic `:erlang.phash2` on the recipient) and `get_sampling_rate/0` remains used by config + interceptor.
- **Archiver/log/rate-limiter/metrics fallbacks** — clause order and guards checked (`cleanup_old_logs` clamps before the catch-all; `get_time_window` fallback; `get_period_dates` fallbacks in `Log` and `Metrics`).
- **Webhook pipeline order** — size → rate limit → IP (warn-only when signature verification is on) → timestamp (symmetric window) → parse → signature → process; all rejection paths return 400/413/429, never raise.
- **mix.exs gate change** — `docs --warnings-as-errors` appended to `precommit`; `skip_code_autolink_to` covers the two intentionally-hidden references. Gate green at base.
- **mix.lock commits** — routine bumps only; phoenix_kit 3.6.0 → 3.7.0 satisfies the `>= 3.5.0 and < 4.0.0` pin and every core API the new code calls exists in 3.7.0 (`Scope.has_module_access?/2`, `Permissions.enabled_module_keys/0`, `Routes.path/2` with `locale: :none`).
- **Tests** — the pure tests assert the real contracts; the integration tests correctly noted the module-permission plug redirects without a scope.

## Findings in this pass

### 1. [BUG - HIGH] Metrics CSV export 500'd on every request — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/export_controller.ex`

`generate_metrics_csv/2` mapped `metric_to_csv_row/1` over every entry of `Emails.get_engagement_metrics/1`'s result, but that map's values are summary scalars (`bounce_rate: 0.0`, …) plus a `daily_stats` list — `metric_to_csv_row({:bounce_rate, 0.0})` called `Access.get(0.0, :label)` → `FunctionClauseError` → 500. Invisible before `6f06570` because the route itself 500'd first; surfaced by the new positive export test. Fix: the CSV now emits the scalar summary as `Metric,Value` rows followed by the daily series as its own table; the unused `group_by` plumbing (headers that never matched the data) was removed. JSON export unchanged. Locked in by an integration test asserting 200 + `Metric,Value` + `bounce_rate` in the body.

### 2. [BUG - MEDIUM] `Emails.get_system_stats/1` still crashed on an unknown period — FIXED

**File:** `lib/phoenix_kit/modules/emails/emails.ex`

The previous pass added period fallbacks to `Metrics.get_time_range/1` and `Log.get_period_dates/1` but missed `Emails`' own `get_period_dates/1`, so the public `Emails.get_system_stats/1` (and `Metrics.get_metric_alerts/1` built on it) still raised `FunctionClauseError` on an unknown period — the dashboard survived only via the `safe/2` wrapper. Added the same fallback (`_other -> :last_30_days`, the function's own default). Covered by a new integration test.

### 3. [IMPROVEMENT - MEDIUM] Export integration tests only proved "not a 500" — IMPROVED

**File:** `test/phoenix_kit/modules/emails/code_review_integration_test.exs`

The old export tests redirected at the permission plug before reaching the action, so the csv/json/400 branches were untested. The tests now register the module with `PhoenixKit.ModuleRegistry` (started on demand — the test app doesn't boot it) and pass a wildcard-superadmin `%Scope{}`, asserting real 200s for logs csv/json, blocklist, metrics csv/json, a 400 for an unsupported format, and a redirect (not 500) for an unknown email id.

### 4. [OBSERVATION] `Paths.export_metrics/1` / `export_blocklist/1` are defined but unlinked

The metrics and blocklist admin pages export via LiveView `push_event("download", …)`, not the controller routes, so those two helpers have no caller. They're public API on `Paths` and the routes are functional, so left as-is — just noted so nobody reads them as wired-up UI links.

### 5. [OBSERVATION] CHANGELOG didn't mention the 3.7.0 lockfile bump

The two "lib upgrades" commits moved phoenix_kit 3.6.0 → 3.7.0 (plus ~20 transitive bumps). 0.10.0's own entry documented its lockfile resolution the same way, so the Unreleased section now does too, along with the new `docs --warnings-as-errors` precommit step.

## Gate

`mix precommit` green after the fixes: compile `--warnings-as-errors`, 923 tests + 12 doctests, `credo --strict`, `format`, dialyzer, `docs --warnings-as-errors`, `hex.audit`, `deps.unlock --check-unused`.
