# Adopting the emails tables: what V1 does, and what has to happen next

**2026-08-12** · Landed in `phoenix_kit_emails` on branch `multiaccount-tracking`
(PR #32), in `PhoenixKit.Modules.Emails.Migrations` V1.

## TL;DR

Six tables that this package is the only consumer of are still created by
**core**, in its squashed `V135` baseline. (Only *consumer* — not only
*dependent*: core's chain also carries a foreign key into one of them. That
distinction is the subject of "What excluding migrations hid" below, and it is
the main thing standing between this and the follow-up core release.) `PhoenixKit.Modules.Emails.Migrations`
V1 now *also* creates them, shape-identically. Right now **both** create them —
that duplication is deliberate and temporary. The next step is a core release
that stops creating them, after which this chain is their only creator.

Nothing about existing installs changes: every statement is idempotent, and on a
database that already has the tables the entire adoption is a no-op. The only
object V1 actually adds is the `integration_uuid` column on
`phoenix_kit_email_logs` (plus the `pke_schema:1` marker).

This is the same move `phoenix_kit_legal` made for `phoenix_kit_consent_logs`,
for the same reason, and its `2026-08-10-module-migration-versioning.md` /
`2026-08-10-consent-logs-extraction.md` reports are the precedent this one
follows.

## Which tables

Adopted (6):

| Table | Consumer in this package |
|---|---|
| `phoenix_kit_email_logs` | `Emails.Log` |
| `phoenix_kit_email_events` | `Emails.Event` |
| `phoenix_kit_email_blocklist` | `Emails.RateLimiter` |
| `phoenix_kit_email_templates` | `Emails.Template` |
| `phoenix_kit_email_metrics` | *(none — see below)* |
| `phoenix_kit_email_orphaned_events` | *(none — see below)* |

Not adopted (1):

| Table | Why not |
|---|---|
| `phoenix_kit_email_send_profiles` | **Core owns and uses it.** `PhoenixKit.Email.SendProfile` and `PhoenixKit.Email.SendProfiles` live in core and drive `PhoenixKit.Mailer`'s send path with or without this package installed. This package only *reads* it (`AwsIntegrations`, `BrevoIntegrations`). Adopting a table core itself depends on would be the mirror of the mistake the legal report documents — claiming ownership of something that outlives you. |

### How the list was established

1. Every table the manifest declares whose name matches `phoenix_kit_email*`
   (7 candidates).
2. For each, `grep` over the whole of core's `/app/lib` — **including
   `lib/phoenix_kit/migrations/`**, which the first pass of this report
   excluded and should not have; see "What excluding migrations hid" below.
3. Only `phoenix_kit_email_send_profiles` has a core RUNTIME consumer
   (`lib/phoenix_kit/email/send_profile.ex`), which is why it is not adopted.
4. `phoenix_kit_email_logs` / `phoenix_kit_email_events` appear in
   `mix phoenix_kit.doctor` and `mix phoenix_kit.repair_uuid`, but only as
   entries in generic integrity sweeps (null-uuid scan, orphaned-FK scan) that
   probe for the table's existence before touching it. Those are auditors over
   whatever exists, not core business logic, so they do not make the tables
   core's.
5. Cross-checked every module package actually in the host's dependency tree
   (`phoenix_kit_ai`, `phoenix_kit_comments`, `phoenix_kit_dashboards`,
   `phoenix_kit_entities`, `phoenix_kit_inbox`, `phoenix_kit_legal`,
   `phoenix_kit_newsletters`, `phoenix_kit_og`, `phoenix_kit_publishing`,
   `phoenix_kit_sync`, `phoenix_kit_web_analytics`) and the host app itself:
   no code in any of them references an adopted table.

### What excluding migrations hid

Restricting the grep to runtime code answered "who READS these tables" and
silently skipped "who DEPENDS on them". Two things turn up once
`lib/phoenix_kit/migrations/` is included, and both change the next step:

* **`fk_newsletters_broadcasts_template`** (`v135.ex:7838`) —
  `phoenix_kit_newsletters_broadcasts.template_uuid` REFERENCES
  `phoenix_kit_email_templates(uuid)`. A core-created foreign key into an
  adopted table. Core's chain runs before every module chain
  (`phoenix_kit.update.ex:734`), so a core release that stops creating
  `phoenix_kit_email_templates` breaks a fresh install outright — and breaks it
  permanently on an install that does not have this package at all. The
  manifest already labels this constraint `owner: :newsletters`, so it is not
  even core's own object; it is one module's FK into another module's table.
* **`uuid_fk_columns.ex:107-266`** — core's UUID conversion machinery names
  `phoenix_kit_email_logs`, `phoenix_kit_email_blocklist`,
  `phoenix_kit_email_templates` and `phoenix_kit_email_events` explicitly
  (column renames, and the events → logs FK rebuild). Historical migration
  machinery rather than a live object, but it is core code that assumes these
  tables exist.

Neither changes which tables are adopted. Both change what the core release has
to do first.

### The two tables with no consumer

`phoenix_kit_email_metrics` and `phoenix_kit_email_orphaned_events` have no Ecto
schema and no query anywhere in the ecosystem — pre-extraction leftovers from
when email tracking lived in core (both `since: 22`). They are adopted anyway:
nothing else touches them, and leaving them out would strand them with no owner
at all the moment core stops creating them. If a later cleanup decides to drop
them, that is a deliberate, separate decision with a migration of its own — not
a side effect of this one.

## Where the DDL came from

**Mechanically extracted from core's `PhoenixKit.Migrations.ExpectedSchema`** —
the same object manifest `mix phoenix_kit.doctor` and `mix phoenix_kit.repair`
verify a live database against. Not retyped from `v135.ex` by hand, because
hand-copying is precisely how `phoenix_kit_legal` ended up with three
disagreeing DDL copies of one table.

Using the manifest rather than the baseline also means the statements carry the
**current** shape (V135 baseline *plus* the V136–V166 deltas), not a snapshot
that was already stale the day it was written.

161 objects: 6 tables, 96 columns, 7 constraints (6 primary keys + the
`phoenix_kit_email_events → phoenix_kit_email_logs` foreign key), 52 indexes.

`test/phoenix_kit/modules/emails/migrations_test.exs` keeps this honest: it
compares every emitted statement against the live manifest, for two different
schema prefixes, and fails on drift. It deliberately **skips objects the
manifest no longer declares**, so the core release that removes them is not
blocked by its own success.

### Two things the extraction got wrong at first

Both were caught by replaying the chain against a real database, not by reading
code. Worth recording, because the next person adopting a table will hit them.

**1. The manifest's column DDL is *repair* DDL, and it drops `NOT NULL`.**
The manifest emits `CREATE TABLE ... ()` plus one
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` per column, and that per-column form
omits `NOT NULL` whenever the column has no default — because adding such a
column to a *populated* table is impossible. Replaying only that form on an
empty database produced **26 nullable columns that core creates `NOT NULL`**.

Fixed by emitting a full `CREATE TABLE IF NOT EXISTS ... (<column list>)` — core's
own baseline form, and the form `phoenix_kit_legal` uses — reconstructed from the
manifest's per-column *shape* (`type` / `default` / `not_null` / `pos`), with the
repair-form `ADD COLUMN IF NOT EXISTS` statements still emitted afterwards so an
existing table missing a column is healed exactly the way core heals it.

**2. A handful of core index names embed the schema prefix in the name itself.**
`phoenix_kit_email_templates_uuid_idx` is one: core's V56 convention names it
bare on `public` and `"<prefix>_"`-prefixed everywhere else, carried in the
manifest as a `__PK_NAME_EXEMPT__` marker. Flattening that marker to its
public-schema spelling would have created a *second*, differently-named index on
every non-public install. The marker is now carried through and resolved the
same way core resolves it.

### Verification against a real database

On a scratch database: run core's full chain, snapshot the six tables from
`information_schema` / `pg_indexes` / `pg_constraint`, `DROP TABLE ... CASCADE`
all six, replay `up_statements/1`, snapshot again.

```
core-created: 96 columns, 58 indexes, 7 constraints
after drop:   0 of the tables remain
adopted:      97 columns, 59 indexes, 7 constraints   # +integration_uuid, +its index
columns:     IDENTICAL
constraints: IDENTICAL
indexes:     2 cosmetic differences (below)
second run:  ok, marker=1                              # idempotent
```

The two index differences are `pg_get_indexdef` renderings of the same
predicate: core's V137 wrote `WHERE event_type NOT IN ('open', 'click')`, the
manifest carries the round-tripped `<> ALL (ARRAY[...]::text[])` form. Same
index, same name, same semantics, different parse tree. Core's own repair path
emits the manifest form too, and nothing compares index definitions textually
(the manifest's `check` is a catalog existence probe by name). Accepted, and
documented in the module's moduledoc.

Re-run after the constraint-safety changes above: columns and constraints are
still IDENTICAL (the foreign key comes back validated, because the fresh
tables are empty), and the index diff is unchanged.

## What is verified, and what is only asserted

`migrations_test.exs` compares every emitted statement against the live
manifest for two schema prefixes, pins the manifest's per-class object counts
(6 tables / 96 columns / 7 constraints / 52 indexes) so a broken filter cannot
make the comparison pass vacuously, and holds a `@declared_departures` map that
fails BOTH on an undeclared departure and on a declared one that no longer
departs.

That is all string equality, so `migration_runner_test.exs` does the other
half: it drives `up/1` and `down/1` through a real `Ecto.Migrator` against the
real database (over a second, unsandboxed connection, because the migrator runs
each migration in a `Task` that checks out its own connection), asserts the
marker moves, asserts `down/1` leaves every table and the added column
standing, and asserts `migration_module/0` actually points at this chain —
without which core would silently skip the module and every string-level
assertion would still pass.

## What is still core's

The chain depends on two core-created objects and does **not** try to own them:

* `uuid_generate_v7()` — used in every `uuid` column default;
* the `pg_trgm` extension, behind the `gin_trgm_ops` operator class in three
  trigram indexes. Note `public.gin_trgm_ops` stays schema-qualified as `public.`
  even under a custom prefix: an operator class lives in the schema its
  *extension* was installed into, not in the install's own schema. Core hard-codes
  it for the same reason.

Core's chain runs before any module chain (`mix phoenix_kit.update` runs core,
then `run_module_migrations/1`), so both are always in place first.

## The transitional state, precisely

**Today.** Core's `V135` baseline creates the six tables. This chain also
creates them. Whichever runs first wins; the other is a no-op, and the shapes
agree, so it does not matter which. Core's `ExpectedSchema` still declares all
161 objects as core-owned, and `mix phoenix_kit.doctor` still audits them —
correctly, because the shapes match.

**The protocol already has a slot for this.** Every manifest object carries an
`owner:` field, and it is already used for module ownership, not just `:core` —
`:ai`, `:catalogue`, `:comments`, `:crm`, `:document_creator`, `:locations`,
`:newsletters`, `:og_images`, `:projects` all appear, and
`phoenix_kit_newsletters_broadcasts` is `owner: :newsletters` today. Our six
tables and their 161 objects are simply still labelled `owner: :core`. So the
"excluded-object protocol" is less an invention than two concrete changes:
relabel these objects `owner: :emails`, and teach `doctor`/`repair` to honour
the field — **nothing in `lib/phoenix_kit/migrations/` reads `owner` at all
today**, so it is currently declarative only.

The one shape change V1 makes — `phoenix_kit_email_logs.integration_uuid` —
is *not* in core's manifest and shows up as an `:info`-level
`"<id>: extra column, not in the manifest"` finding
(`PhoenixKit.Migrations.Repair`). `:info` is not a failure, no core release is
required for it, and that was checked before shipping.

**Next: the core release.** For core to stop creating these tables, three things
have to happen together, and the middle one is the part with no precedent yet:

1. **Core's baseline stops emitting them.** Removing the DDL from a *squashed
   baseline* is not the same as adding a new version — the baseline is the
   unconditional floor every install replays. The mechanics belong to core's
   squash tooling (`dev_docs/squash/generate_baseline.exs`), not here.
2. **`ExpectedSchema` gains an excluded-object protocol.** The manifest is
   generated from a real migrated database, so it will keep *seeing* these
   tables as long as any module creates them. It needs a way to say "this
   object exists but is not mine", or `doctor`/`repair` will keep claiming
   ownership — and, worse, `repair` would keep offering to recreate them on a
   database where the module is not installed at all. This is the same
   excluded-object protocol `phoenix_kit_legal`'s extraction report names as
   its own prerequisite for a V2+; whichever package gets there first should
   build it for both.
3. **A version floor.** Once core stops creating the tables, a host running
   *this* package against an older core is fine (both create them), but a host
   running a *newer* core against an older `phoenix_kit_emails` gets no tables
   at all. That needs a `phoenix_kit` version floor in this package's `mix.exs`
   at the release that drops them, and a `below_floor_error`-style message
   rather than a missing-relation crash.
4. **The cross-module foreign key and the seeds have to move in the same
   release.** Two core-chain objects reach into an adopted table and would
   break a fresh install the moment core stops creating it:
   * `fk_newsletters_broadcasts_template` (see "What excluding migrations
     hid"). It must move into `phoenix_kit_newsletters`' own chain — which
     then needs `phoenix_kit_email_templates` to exist first, i.e. an ordering
     guarantee between two module chains that
     `phoenix_kit.update`'s `run_module_migrations/1` does not currently
     provide — or be dropped, or be made conditional on the table existing.
   * The two seed objects on `phoenix_kit_email_templates`:
     `seed:phoenix_kit_email_templates:system_seeder` (`since: 15`,
     `Mix.Tasks.PhoenixKit.SeedTemplates.run/1`) and
     `seed:phoenix_kit_email_templates:billing_seeder` (`since: 31`,
     `PhoenixKit.Modules.Emails.Templates.seed_system_templates/0`). Both are
     `presence: :required` and both `check:` with
     `SELECT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_templates)`.
     On an install without this package, that check stops meaning "the object
     is absent" and starts meaning "relation does not exist" — an error, not a
     finding. (The second one already calls INTO this package, so it is a
     module seed wearing a core label.)

Until all four land, the duplication stays. It is cheap: six idempotent
`CREATE TABLE IF NOT EXISTS` that find their tables already there.

## Running this on a database that has been alive for years

This chain is the first thing to replay these tables' CONSTRAINTS on existing
installs — core's baseline does not re-run on them — and core itself documents
that those constraints drift. `v163.ex:5-36` was written because a production
database had `phoenix_kit_email_events.uuid` as a nullable `varchar` with no
primary key at all; `v163.ex:70-77,180-215` gives up past a row-count or
lock threshold and legally leaves a database unrepaired; and
`phoenix_kit.doctor.ex:695-702` ships a dedicated check for orphaned
`phoenix_kit_email_events.email_log_uuid` rows, which exists because such rows
are real. Replayed naively, in one transaction, any of those aborts the host's
entire migration.

So the constraint statements deliberately differ from core's manifest:

* **`SET LOCAL lock_timeout = '5s'` is the first statement.** Postgres takes
  the lock BEFORE evaluating `IF NOT EXISTS`, so even a fully no-op run wants
  `ACCESS EXCLUSIVE` on `phoenix_kit_email_logs` 96 times. One long-running
  reader would otherwise hang the deploy and queue every query on that table
  behind it. (V163 sets the session-level equivalent for the same reason.)
* **Primary keys are probed by `contype = 'p'`, not by constraint name.** A
  table whose PK exists under a different name passes a name probe and then
  fails with "multiple primary keys for table are not allowed".
* **The foreign key is added `NOT VALID`**, then validated only when the table
  is empty (a fresh install, where it is free and cannot fail) inside an
  exception-swallowing `DO` block. A populated table keeps the constraint
  enforced for new rows and leaves validation to `mix phoenix_kit.repair`,
  once someone has decided what to do with the orphans.
* **`to_regclass/1`** rather than a `::regclass` cast, so a missing table
  skips its constraint instead of raising mid-transaction.
* **Every constraint checks the actual column TYPES first, on both sides of
  the foreign key, and every constraint and index runs inside an
  exception-swallowing block.** This is the one that makes the rest of the
  list mean anything. `ADD COLUMN IF NOT EXISTS` matches on NAME alone, so on
  the database V163 describes — `phoenix_kit_email_events.uuid` as a nullable
  `character varying` — the column is "already there" and stays the wrong
  type. The constraint that follows then fails at ADD time, on the type
  mismatch, which `NOT VALID` does nothing about because it only defers the
  ROW scan. Same for a primary key on a table with duplicate or NULL uuids,
  and same for a UNIQUE index that is genuinely missing on a table that has
  since accumulated duplicates.

  Verified end to end rather than argued: `dev_docs/verify/drift_replay.exs`
  builds exactly that drift on a scratch database and replays the chain.

  ```
  drift in place: uuid is varchar, no pkey, no fk, duplicate rows present
  REPLAY: completed without raising
  marker after replay: "pke_schema:1"
  drifted table got a pkey: false      # skipped with a NOTICE, not forced
  drifted table got the fk:  false
  UNdrifted table kept its pkey: true  # everything else still applied
  replay with a duplicate blocking a UNIQUE index: :ok
  ```

  The same script against the chain as it stood before these guards:

  ```
  REPLAY: RAISED — ERROR 23505 could not create unique index "phoenix_kit_email_events_pkey"
  ```

  That is the host's entire migration aborting, on a database whose actual
  problem is something `mix phoenix_kit.repair` is supposed to fix. The chain
  now leaves that repair to core and gets out of the way.

**Run `mix phoenix_kit.doctor` before upgrading.** It reports exactly the two
conditions that make these statements interesting — a drifted
`phoenix_kit_email_events` shape and orphaned `email_log_uuid` rows — and it is
cheaper to know beforehand than to learn it from a failed deploy.

## What `down/1` does not do

`down/1` unstamps the `pke_schema:<N>` marker and nothing else. It never drops a
table and never drops a column.

This is not caution for its own sake — it is the exact trap the legal report
documents. There, a `down/1` that ran `DROP TABLE ... CASCADE` on a *core-owned*
table sat unreachable only because the version marker was never set; the PR that
fixed version tracking armed it, and the review found "no blocking issues". The
ownership test here (`"nothing this chain emits can drop a table or a column"`)
asserts that no statement this module can produce matches `DROP`, so the same
mistake cannot be made silently.
