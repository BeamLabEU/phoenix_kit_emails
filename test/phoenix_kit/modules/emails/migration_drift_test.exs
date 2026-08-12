defmodule PhoenixKit.Modules.Emails.MigrationDriftTest do
  @moduledoc """
  Replays the chain against a database whose shape has DRIFTED, and asserts it
  degrades instead of aborting.

  This is the regression guard for the failure core's V163 documents from a
  real production database: `phoenix_kit_email_events.uuid` as a nullable
  `character varying`, no primary key at all. `ADD COLUMN IF NOT EXISTS`
  matches on name, so the column stays varchar, and the constraint that follows
  fails at ADD time on the type mismatch — taking every other statement in the
  host's migration with it.

  The drift is created inside the test's own sandbox transaction and rolled
  back with it, so this is destructive only to itself. `dev_docs/verify/drift_replay.exs`
  is the same scenario against a throwaway database, for when you want to look
  at the result by hand.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.Repo

  defp drift_email_events! do
    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events DROP CONSTRAINT IF EXISTS fk_email_events_email_log_uuid"
    )

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events DROP CONSTRAINT IF EXISTS phoenix_kit_email_events_pkey CASCADE"
    )

    Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_events_uuid_idx")
    Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_events_log_uuid_event_type_index")

    Repo.query!(
      "DROP INDEX IF EXISTS public.phoenix_kit_email_events_log_uuid_type_occurred_index"
    )

    Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid DROP DEFAULT")
    Repo.query!("ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid DROP NOT NULL")

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN uuid TYPE character varying(255)"
    )

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN email_log_uuid TYPE character varying(255)"
    )

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events ALTER COLUMN email_log_uuid DROP NOT NULL"
    )

    # Rows the drifted table could never satisfy a primary key with, and which
    # also make it "populated" — the state in which failures are swallowed.
    for _ <- 1..2 do
      Repo.query!(
        "INSERT INTO public.phoenix_kit_email_events " <>
          "(uuid, email_log_uuid, event_type, occurred_at, inserted_at, updated_at) " <>
          "VALUES ('dup', 'orphan', 'delivery', now(), now(), now())"
      )
    end
  end

  defp replay do
    Enum.each(Migrations.up_statements("public"), &Repo.query!/1)
    :ok
  rescue
    error -> {:raised, Exception.message(error)}
  end

  defp exists?(sql, params \\ []) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  test "a drifted table does not take the host's migration down with it" do
    drift_email_events!()

    assert replay() == :ok
  end

  test "the drifted constraints are skipped, not forced" do
    drift_email_events!()
    replay()

    refute exists?(
             "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = " <>
               "to_regclass('public.phoenix_kit_email_events') AND contype = 'p')"
           ),
           "a primary key was forced onto a varchar column with duplicate values"

    refute exists?(
             "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = " <>
               "'fk_email_events_email_log_uuid')"
           )
  end

  test "everything that is NOT drifted still gets applied" do
    drift_email_events!()
    replay()

    assert exists?(
             "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = " <>
               "to_regclass('public.phoenix_kit_email_logs') AND contype = 'p')"
           ),
           "a healthy table lost its primary key because another table was drifted"

    assert exists?(
             "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
               "WHERE table_schema = 'public' AND table_name = 'phoenix_kit_email_logs' " <>
               "AND column_name = 'integration_uuid')"
           )

    %{rows: [[marker]]} =
      Repo.query!(
        "SELECT obj_description(c.oid, 'pg_class') FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = 'public' AND c.relname = 'phoenix_kit_email_logs'"
      )

    assert marker == "pke_schema:#{Migrations.current_version()}"
  end

  test "a duplicate row blocking a UNIQUE index does not abort either" do
    Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_logs_message_id_uidx")

    for _ <- 1..2 do
      Repo.query!(~s{
        INSERT INTO public.phoenix_kit_email_logs
          (uuid, message_id, "to", "from", provider, status, inserted_at, updated_at)
        VALUES (public.uuid_generate_v7(), 'dup-msg', 'a@example.com', 'b@example.com',
          'aws_ses', 'sent', now(), now())
      })
    end

    assert replay() == :ok
  end

  test "on an EMPTY table a failure is raised, not swallowed" do
    # The asymmetry that keeps a fresh install honest: with no data to have
    # drifted, a failure can only mean this chain is wrong, and swallowing it
    # would stamp `pke_schema:1` over a genuinely broken schema and report
    # success.
    #
    # Built so the failure lands on the EVENTS table (empty -> raise) while its
    # cause is on the LOGS table (populated -> swallowed): with no unique
    # constraint left on `phoenix_kit_email_logs(uuid)`, the foreign key cannot
    # be created at all.
    Repo.query!("DELETE FROM public.phoenix_kit_email_events")

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_events DROP CONSTRAINT IF EXISTS fk_email_events_email_log_uuid"
    )

    Repo.query!(
      "ALTER TABLE public.phoenix_kit_email_logs DROP CONSTRAINT IF EXISTS phoenix_kit_email_logs_pkey CASCADE"
    )

    Repo.query!("DROP INDEX IF EXISTS public.phoenix_kit_email_logs_uuid_idx")

    duplicate = Ecto.UUID.generate()

    for message_id <- ["dup-a", "dup-b"] do
      Repo.query!(
        ~s{
          INSERT INTO public.phoenix_kit_email_logs
            (uuid, message_id, "to", "from", provider, status, inserted_at, updated_at)
          VALUES ($1, $2, 'a@example.com', 'b@example.com', 'aws_ses', 'sent', now(), now())
        },
        [Ecto.UUID.dump!(duplicate), message_id]
      )
    end

    assert {:raised, message} = replay()
    assert message =~ "unique constraint"
  end
end
