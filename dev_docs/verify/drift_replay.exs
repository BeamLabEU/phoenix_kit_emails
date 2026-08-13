# Replays the migration chain against a DELIBERATELY DRIFTED database.
#
# The claim under test: on a database whose shape has drifted — which core's
# own V163 documents as a real production state — replaying this chain must
# degrade to NOTICEs instead of aborting the host's migration.
#
# Run against a scratch database, never a real one; it mutates the schema on
# purpose:
#
#     createdb phoenix_kit_emails_test_drift
#     MIX_ENV=test mix run dev_docs/verify/drift_replay.exs
#
# The database is chosen HERE, at runtime, not through MIX_TEST_PARTITION.
# `config/test.exs` reads that variable while the config is COMPILED, so
# `MIX_TEST_PARTITION=_drift mix run` against an already-compiled tree
# silently points at the main test database and drifts it — which is exactly
# the mistake this script now refuses to let you make. Override with
# DRIFT_DATABASE if you want a different scratch name.
#
# Expected output:
#
#     REPLAY: completed without raising
#     marker after replay: "pke_schema:1"
#     drifted table got a pkey: false      # skipped, not forced
#     drifted table got the fk:  false
#     UNdrifted table kept its pkey: true  # everything else still applied
#     replay with a duplicate blocking a UNIQUE index: :ok
#
# Against the chain as it stood before the guards, the same script prints
#     REPLAY: RAISED — ERROR 23505 could not create unique index "phoenix_kit_email_events_pkey"
# which is the host's entire migration going down.

alias PhoenixKit.Modules.Emails.Migrations
alias PhoenixKitEmails.Test.Repo

database = System.get_env("DRIFT_DATABASE", "phoenix_kit_emails_test_drift")

# Refuse anything that is not obviously a throwaway. This script drops
# constraints and indexes and inserts junk rows; pointed at a real database it
# is destructive, and pointed at the package's own test database it breaks the
# suite in ways that look like unrelated UTF-8 errors half an hour later.
unless String.contains?(database, "drift") do
  IO.puts("""
  REFUSING TO RUN against #{inspect(database)}.

  This script deliberately corrupts the schema it runs against. Its database
  name must contain "drift" so it cannot be aimed at anything real:

      createdb phoenix_kit_emails_test_drift
      MIX_ENV=test mix run dev_docs/verify/drift_replay.exs
  """)

  System.halt(1)
end

# Set at RUNTIME so the target cannot be inherited from a stale compiled
# config — see the header.
Application.put_env(
  :phoenix_kit_emails,
  Repo,
  Application.get_env(:phoenix_kit_emails, Repo)
  |> Keyword.put(:database, database)
  |> Keyword.put(:pool_size, 2)
  |> Keyword.delete(:pool)
)

IO.puts("target database: #{database}")

{:ok, _} = Repo.start_link()
PhoenixKit.Migration.ensure_current(Repo, log: false)
Enum.each(Migrations.up_statements("public"), &Repo.query!/1)

# --- Reproduce the drift core's V163 documents: phoenix_kit_email_events.uuid
# --- as a nullable character varying, no primary key, and a varchar FK column.
Repo.query!("ALTER TABLE public.phoenix_kit_email_events DROP CONSTRAINT IF EXISTS fk_email_events_email_log_uuid")
Repo.query!("ALTER TABLE public.phoenix_kit_email_events DROP CONSTRAINT IF EXISTS phoenix_kit_email_events_pkey CASCADE")
Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid DROP DEFAULT")
Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid DROP NOT NULL")
Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid TYPE character varying(255)")
Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN email_log_uuid TYPE character varying(255)")

# A duplicate + a NULL, so even a same-type PK could not be created.
Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN email_log_uuid DROP NOT NULL")
Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_events_uuid_idx")
Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_events_log_uuid_event_type_index")
Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_events_log_uuid_type_occurred_index")

for _ <- 1..2 do
  Repo.query!(
    "INSERT INTO public.phoenix_kit_email_events (uuid, email_log_uuid, event_type, occurred_at, inserted_at, updated_at) " <>
      "VALUES ('dup', 'orphan', 'delivery', now(), now(), now())"
  )
end

IO.puts("drift in place: uuid is varchar, no pkey, no fk, duplicate rows present")

# --- The claim under test: replaying the chain must not abort. --------------
result =
  try do
    Enum.each(Migrations.up_statements("public"), &Repo.query!/1)
    :ok
  rescue
    e -> {:raised, Exception.message(e)}
  end

case result do
  :ok ->
    IO.puts("REPLAY: completed without raising")

  {:raised, message} ->
    IO.puts("REPLAY: RAISED — #{message}")
end

# --- ...and the rest of the chain must still have been applied. -------------
%{rows: [[marker]]} =
  Repo.query!(
    "SELECT obj_description(c.oid, 'pg_class') FROM pg_class c " <>
      "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
      "WHERE n.nspname = 'public' AND c.relname = 'phoenix_kit_email_logs'"
  )

IO.puts("marker after replay: #{inspect(marker)}")

%{rows: [[has_pk]]} =
  Repo.query!(
    "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = " <>
      "to_regclass('public.phoenix_kit_email_events') AND contype = 'p')"
  )

%{rows: [[has_fk]]} =
  Repo.query!(
    "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = " <>
      "'fk_email_events_email_log_uuid')"
  )

IO.puts("drifted table got a pkey: #{has_pk} (expected false — skipped, not forced)")
IO.puts("drifted table got the fk:  #{has_fk} (expected false)")

%{rows: [[logs_pk]]} =
  Repo.query!(
    "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = " <>
      "to_regclass('public.phoenix_kit_email_logs') AND contype = 'p')"
  )

IO.puts("UNdrifted table kept its pkey: #{logs_pk} (expected true)")

%{rows: [[idx]]} =
  Repo.query!(
    "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' " <>
      "AND tablename = 'phoenix_kit_email_logs'"
  )

IO.puts("indexes on phoenix_kit_email_logs: #{idx}")

# --- A missing unique index on a table with duplicates must not abort either.
Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_logs_message_id_uidx")

Repo.query!(
  "INSERT INTO public.phoenix_kit_email_logs (uuid, message_id, \"to\", \"from\", provider, status, inserted_at, updated_at) " <>
    "VALUES (public.uuid_generate_v7(), 'dup-msg', 'a@example.com', 'b@example.com', 'aws_ses', 'sent', now(), now())"
)

Repo.query!(
  "INSERT INTO public.phoenix_kit_email_logs (uuid, message_id, \"to\", \"from\", provider, status, inserted_at, updated_at) " <>
    "VALUES (public.uuid_generate_v7(), 'dup-msg', 'a@example.com', 'b@example.com', 'aws_ses', 'sent', now(), now())"
)

index_result =
  try do
    Enum.each(Migrations.up_statements("public"), &Repo.query!/1)
    :ok
  rescue
    e -> {:raised, Exception.message(e)}
  end

IO.puts("replay with a duplicate blocking a UNIQUE index: #{inspect(index_result)}")
