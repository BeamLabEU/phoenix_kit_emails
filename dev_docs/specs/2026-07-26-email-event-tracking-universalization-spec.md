# Spec: Universalize email event-tracking (pollers) + clear admin surface

**Date:** 2026-07-26
**Module:** `phoenix_kit_emails`
**Builds on (already landed):** Oban-`unique` self-scheduling poller chains
(`unique: [states: [:scheduled]]` in both poller jobs — PR BeamLabEU/phoenix_kit_emails#21,
**merged 2026-07-26**) and `Oban.Plugins.Lifeline` in host configs (PR BeamLabEU/phoenix_kit#662).
The "exactly one chain" + "let a chain die when it shouldn't run" mechanics the reconciler
needs therefore **exist today** — this spec composes on top of them, it does not add them.
**Status:** REVISED after GLM review (verdict SOUND-WITH-CHANGES) — ready for agent implementation.
Review findings folded into §3–§10; the five open questions are now **Decisions (§9)**.

---

## 1. Problem

Delivery-event tracking (delivered / bounced / opened / clicked …) is fetched by a
per-provider background poller. Today there are two, hand-wired independently:

- **SES** — events arrive over SNS→SQS; `SQSPollingJob` (self-scheduling Oban job) +
  `SQSPollingManager` (enable/disable/poll_now/status/interval) + the
  `amazon_ses_sqs` settings section.
- **Brevo** — events pulled from Brevo's events API; `BrevoPollingJob` +
  `BrevoPollingManager` (its moduledoc literally says *"Mirrors `SQSPollingManager`"*) +
  the `brevo_events` settings section.

Sending is provider-driven too: a `SendProfile.provider_kind` (`aws_ses` / `brevo_api` /
`smtp`) selects the transport, and the matching poller (if any) is what turns raw
provider events into `email_log` status transitions. A `smtp`-kind profile has **no**
tracker, so those logs never advance past `sent` (confirmed empirically: all `smtp`
logs sit at `sent`/`failed`, while `aws_ses` and `brevo_api` show the full lifecycle).

Three concrete defects follow from the hand-wired design:

### 1.1 Asymmetric startup (latent bug)
`Emails.Supervisor.init/1` → `build_oban_starter/0` → `start_oban_polling_when_ready/0`
starts **only** the SQS chain at boot. **Nothing** starts the Brevo chain at boot: the
only call site of `BrevoPollingManager.enable_polling/0` is the `brevo_events` settings
UI toggle (`web/settings_sections/brevo_events.ex:47`). The Brevo chain keeps running
after a toggle only because its self-scheduling Oban job persists in `oban_jobs` across
restarts. On a fresh database, or if that scheduled job is ever lost (prune, cancel,
crash), **Brevo polling silently stops until a human re-toggles it**. This is why "when
do they turn on?" is unclear — for Brevo, the honest answer today is "only when someone
flips the switch, and it survives on luck".

### 1.2 Lifecycle is not integration-driven
Neither poller (re)starts when an integration is **added**, nor stops when the **last**
integration of a kind is removed. Add a `brevo_api` integration → nothing polls until
`brevo_events` is also toggled. Remove the last one → the chain keeps ticking as a
no-op. The invariant the user expects — *"a provider's tracker exists and does work only
if a matching integration exists"* — holds at **run time** (each cycle's `should_poll?` /
`active_brevo_integrations` returns empty → no-op) but **not at lifecycle time** (nothing
starts/stops the chain based on integration presence).

### 1.3 No abstraction — copy-paste per provider
Adding a third provider (e.g. Mailgun) today means cloning: a Job, a Manager
(near-identical to the existing ones), a settings section, **and** remembering to wire a
boot starter — the exact step that was forgotten for Brevo (§1.1). There is no registry,
no behaviour, no single place that knows "these are the trackers". It does not scale and
it is error-prone.

---

## 2. Goals / non-goals

### Goals
1. **One uniform lifecycle** for every provider tracker: it runs **iff**
   `(a matching active integration exists) AND (its events toggle is on)` — enforced
   automatically at boot, on integration add/enable/disable/remove, and on the toggle.
2. **A provider adds a tracker by implementing a behaviour + registering** — no bespoke
   boot code, no copy-pasted manager, nothing to forget. Mailgun becomes "implement +
   register", full stop.
3. **A clear admin surface**: a single panel listing every registered tracker with an
   at-a-glance, unambiguous state (eligible? / enabled? / running? / last poll / pending
   job / per-integration opt-out) and a per-tracker toggle. Registry-driven, so a new
   provider appears automatically.
4. **Fix §1.1** (Brevo not bootstrapped) as part of the change — ideally it simply
   disappears because the orchestrator bootstraps *all* trackers uniformly.
5. **No regressions**: SES/SQS and Brevo keep working exactly as before; existing
   settings keys, per-integration opt-out, intervals, on-demand refresh, and the
   Oban-unique single-chain guarantee (#21) are preserved.

### Non-goals
- Building the Mailgun tracker itself (this spec makes it *cheap*; a separate task adds it).
- Adding tracking for generic (non-ESP) SMTP — impossible without an events source; out of scope.
- Reworking the send path, `SendProfile`, or `deliver_via_integration/3`.
- Changing how events map to `email_log` transitions (`SQSProcessor` stays as-is).

---

## 3. Current architecture (grounded)

| Piece | SES | Brevo |
|---|---|---|
| Job (self-scheduling) | `SQSPollingJob` | `BrevoPollingJob` |
| Manager | `SQSPollingManager` | `BrevoPollingManager` |
| Settings section | `web/settings_sections/amazon_ses_sqs.ex` | `web/settings_sections/brevo_events.ex` |
| Master toggle key | `sqs_polling_enabled` | `brevo_events_enabled` |
| Feature/eligibility key | `email_ses_events` (default `true`, `emails.ex:1105` — "track SES events at all") | (no separate key; eligibility = active `brevo_api` profiles) |
| Interval key | `sqs_polling_interval_ms` | `brevo_polling_interval_ms` |
| "Has an integration?" gate | `Supervisor.has_sqs_configuration?/0`, `SQSPollingJob.should_poll?/0` (`ses_actively_configured?`) | `BrevoPollingJob.active_brevo_integrations/0` (enabled `brevo_api` send profiles) |
| Per-integration opt-out | — | `brevo_polling_excluded_integrations` (comma list) via `Emails.get/set_brevo_polling_excluded_integrations/*` |
| Boot start | ✅ `Emails.Supervisor` | ❌ **none** — UI toggle only |
| On-demand refresh | — | `BrevoOnDemandSync` (log `provider == "brevo_api"`) |

Manager API (shared shape both already expose): `enable_polling/0`, `disable_polling/0`,
`poll_now/0`, `status/0`, `set_polling_interval/1`.

Registration precedent already in the ecosystem (core `PhoenixKit.ModuleRegistry`):
`all_settings_tabs/0`, `all_email_settings_sections/0`, `all_reserved_route_prefixes/0`
collect per-module contributions. The tracker registry mirrors this pattern.

---

## 4. Design

### 4.1 The `EventTracker` behaviour
A new behaviour (in `phoenix_kit_emails`, e.g.
`PhoenixKit.Modules.Emails.EventTracking.Tracker`) that every provider tracker
implements. Callbacks (final names to be settled in review):

- `provider_kind() :: String.t()` — `"aws_ses"` / `"brevo_api"` / `"mailgun"`. The
  discriminator; matches `SendProfile.provider_kind`.
- `label() :: String.t()` — human name for the admin panel ("Amazon SES", "Brevo").
- `eligible?() :: boolean()` — is there a **working event source** this tracker can poll?
  This is the *"only if an integration exists"* rule, per provider. **Resolution of the
  SES three-gate (GLM gap 3b):** SES's `should_poll?/0` gates on `enabled?() AND
  email_ses_events AND sqs_polling_enabled` — three things, not two. The clean split:
  `eligible?` folds the *feature/source* gates — SES: SQS configured **and**
  `email_ses_events` on (`has_sqs_configuration?` + the feature flag); Brevo:
  `active_brevo_integrations != []`. `enabled?` is only the operator's **polling** switch.
  So `email_ses_events` is an eligibility gate ("is SES event tracking a thing here at
  all"), NOT the polling toggle — resolved here so it isn't silently dropped.
- `enabled?() :: boolean()` — the operator's polling master toggle only: SES →
  `sqs_polling_enabled`; Brevo → `brevo_events_enabled`.
- `poll_cycle(context) :: :ok | {:error, term}` — run one poll cycle. For the initial
  migration this delegates to the existing `*PollingJob` logic; the job/worker stays.
- `interval_ms() :: pos_integer()` — cadence for the next self-schedule.
- `worker() :: module()` — the Oban worker module for this tracker's chain (so the
  orchestrator can enqueue/inspect a unique job per tracker).

`should_run?/0` is a derived helper: `eligible?() and enabled?()`.

`SQSPollingJob`+`SQSPollingManager` and `BrevoPollingJob`+`BrevoPollingManager` are
refactored to *implement* this behaviour (thin wrappers over what they already do). The
Managers' `enable/disable/poll_now/status/interval` semantics are preserved but routed
through the orchestrator so behaviour is uniform.

### 4.2 The tracking orchestrator (reconciler)
A single supervised process (or a stateless reconcile function invoked from well-defined
hooks — see 4.3) that owns the invariant:

> For every registered tracker: if `should_run?/0` then exactly one self-scheduling chain
> is queued (`available`/`scheduled`); otherwise none.

Implementation leans directly on #21's Oban-`unique` chains: "ensure exactly one" =
insert a `unique` job for the tracker's worker (no-op if one already exists), and
"ensure none" = the chain self-terminates when its next cycle sees `should_run?/0 = false`
(the same "let the chain die" mechanism #21 already uses for disable), plus an explicit
cancel of any queued job for that worker.

**Reconcile is idempotent** and safe to call repeatedly. It is the single code path that
starts/stops any tracker — replacing the scattered `enable_polling`/`disable_polling`
call sites.

### 4.3 When reconcile runs — and what actually guarantees correctness

**The correctness backbone is a periodic reconcile tick, not the event hooks (GLM gap 3a).**
This is the most important refinement from review, for two compounding reasons:

- The per-cycle `should_run?/0` re-check inside a poller job can only *stop* a chain that is
  **already running** — it **cannot resurrect a dead one** (a dead chain has no cycle to run
  the check). So the per-cycle gate is NOT a self-heal for the "tracker should be running but
  isn't" case (exactly §1.1).
- The dominant act that flips a tracker eligible — creating/enabling a `brevo_api`
  **`SendProfile`** — emits **no PubSub today** (`SendProfiles.create/update/delete_send_profile`
  broadcast nothing; only `Integrations` connect/disconnect broadcast on
  `"phoenix_kit:integrations"`). So an event-driven-only trigger surface would miss the common
  case.

Therefore:

1. **Periodic reconcile (the contract).** A low-frequency scheduled reconcile — an Oban `Cron`
   entry, e.g. every 1–5 min — walks **every** registered tracker and reconciles it
   (start a chain for any `should_run?` tracker that has none; cancel chains for trackers that
   no longer should run). This is the eventual-consistency guarantee: whatever the triggers
   miss, the next tick fixes, and it **can resurrect a dead chain** (unlike the per-cycle gate).
   It is cheap (a handful of `should_run?` checks + one Oban existence query per tracker).
2. **Boot reconcile (latency).** `Emails.Supervisor` calls reconcile once after Oban is ready
   → bootstraps all eligible+enabled trackers immediately instead of waiting up to one tick.
   Fixes §1.1 (Brevo bootstrapped identically to SES).
3. **Integration PubSub (latency).** Subscribe to `"phoenix_kit:integrations"`
   (`:integration_connected/disconnected`) → react to connection changes without waiting a tick.
   **Optional polish, not required for correctness** given (1). Adding a `SendProfile` broadcast
   is likewise optional latency-reduction, not a dependency.
4. **Settings toggle (latency).** The admin panel calls reconcile right after flipping a
   tracker's toggle or editing its per-integration opt-out → instant feedback.

Net: triggers 2–4 make it *feel* instant; trigger 1 makes it *correct* no matter what.

**Decision (was open Q1): stateless reconcile-on-hooks + a reconcile Cron job.** No long-lived
`TrackingOrchestrator` GenServer — the Cron tick is the "self-heal", the admin panel queries
Oban/Settings directly for status, and a stateless reconcile function is crash-free and
**cluster-safe** (see §8a).

### 4.4 Registration
Each provider declares its tracker so the registry can collect them. Two viable routes,
to be decided in review:

- **(A) Module registry (mirrors `all_email_settings_sections/0`)** — a new
  `event_trackers/0` callback on `PhoenixKit.Module`, collected by
  `ModuleRegistry.all_event_trackers/0`. Touches core (one small collector), consistent
  with the existing extension pattern, lets *any* module contribute a tracker.
- **(B) Emails-local registry** — a compile-time list / config in `phoenix_kit_emails`
  itself (the trackers all live here today). No core change; simpler; but a tracker
  shipped by a *different* module couldn't self-register.

Given trackers are an emails-module concern and Mailgun would also live in emails,
**(B) is the pragmatic default**; choose (A) only if out-of-module trackers are a real
requirement. Review to decide.

---

## 5. Admin surface

Replace the two separate provider sections' polling controls with **one registry-driven
"Delivery event tracking" panel** (still surfaced through core's
`email_settings_sections/0` seam so it renders inside the core Emails settings page). One
row per registered tracker, rendered from the registry so a new provider appears
automatically:

| Column | Meaning | Source |
|---|---|---|
| **Provider** | `label()` | tracker |
| **Integration** | eligible? — e.g. "2 active accounts" / "none configured" | `eligible?/0` + count |
| **Tracking** | master toggle (on/off) | `enabled?/0` → sets the settings key → reconcile |
| **State** | one clear status, see below | derived |
| **Last poll** | timestamp of last successful cycle | existing `*_last_polled_at` |
| **Queued** | is a chain job present? (health) | Oban count by worker across `available \| scheduled \| executing` — **exactly** the states the existing `count_pending_jobs` uses (`sqs_polling_manager.ex:269`), never queued-only |
| **Accounts** | per-integration opt-out toggles (where applicable) | existing opt-out |
| **Actions** | "Poll now" | `poll_cycle` / manager |

**Unambiguous State vocabulary** (the "понятная информация" requirement) — exactly one of:

- **Active** — enabled + eligible + a chain is queued (green). Normal.
- **Idle — no integration** — enabled but `eligible? = false` (grey). "Turn it on by
  adding/configuring a matching integration." Not an error.
- **Off** — `enabled? = false` (grey). Operator turned tracking off.
- **Stalled** — `should_run? = true` but **zero** jobs across `available|scheduled|executing`
  (amber, actionable) — surfaces a missed bootstrap/lost job before it becomes silent data
  loss; a "Restart" action calls reconcile. (This is exactly what §1.1 produced invisibly
  today.) **False-positive guard (GLM gap 3d):** a healthy chain inserts its successor
  *synchronously inside `perform` before returning `:ok`, so counting queued-only states
  flickers Stalled every cycle. Two defenses: (i) count `executing` too (above), which closes
  the normal window; (ii) require Stalled to persist across the reconcile Cron's own check
  (the periodic tick would re-queue a genuinely dead chain, so a transient miss self-clears
  within one tick and only a *sustained* absence lights amber).

Copy is written so a non-expert understands *why* a tracker isn't running and what to do.
Estonian/ru/de… gettext for all new strings (fuzzy-checked by hand — known trap).

---

## 6. Backward compatibility & migration

- Keep every existing settings key (`sqs_polling_enabled`, **`email_ses_events`** [GLM 3c —
  this is the real key, not `ses_events_enabled`], `brevo_events_enabled`,
  `brevo_polling_interval_ms`, `sqs_polling_interval_ms`, `brevo_polling_excluded_integrations`)
  — the tracker callbacks read the *same* keys, so operator config carries over untouched.
  No migration/DDL.
- `SQSPollingManager` / `BrevoPollingManager` public functions remain callable
  (delegating to reconcile) so any external caller / IEx muscle-memory keeps working.
- `BrevoOnDemandSync` unchanged.
- The two old settings sections' *polling* controls move into the unified panel; the
  provider-specific bits that are NOT about polling (e.g. SQS queue URL config, Brevo
  API sender identity) stay in their sections.

---

## 7. Phasing

*(GLM: former "P1 — land #21" is dropped — #21 is merged and the unique chains are in the
mainline already. The reconciler builds directly on them.)*

- **P0 (immediate, foldable into the current emails batch, no dependency):** add a Brevo
  boot-starter to `Emails.Supervisor`, symmetric to SES, so Brevo is bootstrapped at boot
  instead of only on toggle. Kills §1.1 now; superseded cleanly by the reconciler later.
- **P1:** the `EventTracker` behaviour + the stateless reconcile function + the **reconcile
  Cron** (the correctness backbone, §4.3.1); refactor SES and Brevo to implement the
  behaviour; wire boot + settings-toggle reconcile; subscribe to `"phoenix_kit:integrations"`
  as latency polish.
- **P2:** the unified admin panel (registry-driven rows, the four-word State vocabulary,
  Queued = `available|scheduled|executing`, gettext).
- **P3 (separate task, proves the design):** Mailgun tracker = implement behaviour +
  register + settings key + `poll_cycle` against Mailgun's events API. No boot/UI/reconcile
  wiring — the registry + Cron pick it up automatically.

---

## 8a. Multi-node / clustering (GLM 3e)

The design is cluster-safe **without node coordination**, and this is by construction, not
accident:
- "Exactly one chain per tracker" is enforced at the **database** by Oban `unique` — two nodes
  reconciling simultaneously cannot create two chains.
- The per-cycle `should_run?/0` gate is the real safety net: even a duplicate insert runs at
  most one extra no-op cycle.
- The reconcile function is **stateless**, so it is safe to run on every node (boot hook fires
  per node; the Cron entry runs on whichever node Oban picks — either way the DB-unique makes
  it idempotent).

No leader election, no global process, no `:global` registry needed.

## 8. Testing

- Behaviour conformance: a shared test asserting each registered tracker implements the
  callbacks and that `should_run?` = `eligible? and enabled?`.
- Reconcile invariant: with a fake tracker, assert exactly one queued job when
  `should_run?`, zero otherwise; idempotent across repeated calls; transitions on
  toggle/integration-change.
- Lifecycle triggers: boot bootstraps all eligible trackers; adding an integration starts
  the matching chain; removing the last stops it; toggling reconciles.
- No-regression: existing SES/Brevo poller suites stay green; on-demand refresh unchanged.
- Watch `N excluded` in every run (shared test-DB trap).

---

## 9. Decisions (were open questions; settled per GLM review)

1. **Reconcile = stateless function + reconcile Cron** (no `TrackingOrchestrator` GenServer).
   The Cron tick is the self-heal; the panel queries Oban/Settings directly; stateless is
   crash-free and cluster-safe (§4.3, §8a).
2. **Registration = emails-local (B).** Trackers live in `phoenix_kit_emails` and so would
   Mailgun; a core module-registry callback (A) adds a core change for a need that doesn't
   exist yet. Revisit A only if a tracker must ship from a different package.
3. **Keep per-provider settings sections for transport/identity** (SQS queue URL, Brevo/SES
   sender identity); **absorb only the polling controls** into the unified panel. Operators
   expect transport config where it already is.
4. **Per-tracker interval + "Poll now"**, surfaced in the one panel. A single global interval
   is wrong — provider minimums differ (SES ≥ 1000 ms `sqs_polling_manager.ex:156`, Brevo
   ≥ 30000 ms `brevo_polling_manager.ex:69`).
5. **Integration-change trigger is partial and that's fine.** Subscribe to the existing
   `"phoenix_kit:integrations"` topic as latency polish, **but the reconcile Cron (§4.3.1) is
   the correctness contract** — because `SendProfile` mutations (the dominant eligibility
   trigger for Brevo) emit no PubSub today. Adding a `SendProfile` broadcast is optional
   follow-up, not a dependency.

## 10. Residual risks / notes
- The reconcile Cron adds one recurring Oban job; interval (1–5 min) trades resurrection
  latency vs churn — pick in implementation, default 2 min.
- `SendProfile`-mutation latency: until/unless a broadcast is added, a newly-added Brevo
  profile can wait up to one Cron tick before its chain starts (boot/toggle paths are still
  instant). Acceptable; documented so it isn't mistaken for a bug.
