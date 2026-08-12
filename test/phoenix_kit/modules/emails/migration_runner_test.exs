defmodule PhoenixKit.Modules.Emails.MigrationRunnerTest do
  @moduledoc """
  Runs the chain the way core runs it: `up/1` and `down/1` inside a real
  `Ecto.Migrator`, against the real database.

  Every other migration test asserts on `up_statements/1`, which is data. That
  leaves two whole classes of failure invisible: `up/1` itself raising or
  no-opping (it is the function core actually calls, and it is the one that has
  to survive `Ecto.Migration`'s `execute/1` queueing), and
  `PhoenixKit.Modules.Emails.migration_module/0` not pointing here at all — in
  which case core would never discover the chain and every data-level
  assertion would still pass. `test_helper.exs` applies the chain by executing
  the statements directly, so it cannot catch either.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Ecto.Migrator
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.MigrationRepo

  @moduletag :integration

  defmodule UpMigration do
    @moduledoc false
    use Ecto.Migration

    alias PhoenixKit.Modules.Emails.Migrations

    def up, do: Migrations.up(prefix: "public")
    def down, do: Migrations.down(prefix: "public", version: 0)
  end

  defmodule PinnedMigration do
    @moduledoc false
    use Ecto.Migration

    alias PhoenixKit.Modules.Emails.Migrations

    # What core's generated migration passes when a host pins a version.
    def up, do: Migrations.up(prefix: "public", version: 0)
    def down, do: :ok
  end

  # Ecto.Migrator runs each migration in a Task that checks out its OWN
  # connection, which a manual-mode sandbox refuses. MigrationRepo is the same
  # database over an ordinary pool — see its moduledoc for why that is the
  # isolation used here rather than flipping the global sandbox mode.
  setup_all do
    start_supervised!(MigrationRepo)
    :ok
  end

  defp marker do
    %{rows: [[description]]} =
      MigrationRepo.query!(
        "SELECT obj_description(c.oid, 'pg_class') FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = 'public' AND c.relname = 'phoenix_kit_email_logs'"
      )

    description
  end

  defp column_exists?(table, column) do
    %{rows: [[exists?]]} =
      MigrationRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2)",
        [table, column]
      )

    exists?
  end

  defp table_exists?(table) do
    %{rows: [[exists?]]} =
      MigrationRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = $1)",
        [table]
      )

    exists?
  end

  @version 29_990_812_000_001
  @pinned_version 29_990_812_000_002

  # Migrator emits an "older migration has already run" warning for these
  # deliberately-high version numbers, and :already_up when a previous test in
  # the same run left the row behind. Both are noise about the schema_migrations
  # bookkeeping, not about the chain — normalise them away so the assertions are
  # about what up/1 and down/1 actually did to the database.
  defp run(direction, version, module) do
    {result, _log} =
      with_log(fn ->
        apply(Migrator, direction, [MigrationRepo, version, module, [log: false]])
      end)

    result
  end

  # State-INDEPENDENT, on purpose. `Ecto.Migrator.down/4` answers `:already_down`
  # and does nothing when the version is absent from `schema_migrations`, which
  # on a freshly created database is always — so a Migrator-based reset left
  # the marker `test_helper.exs` had already stamped, and every test that
  # asserts "we start at version 0" failed on a clean database and passed
  # forever after. Green locally, red on CI, which is the worst shape a test
  # can have.
  defp reset do
    Enum.each(Migrations.down_statements("public", 0), &MigrationRepo.query!/1)

    MigrationRepo.query!(
      "DELETE FROM schema_migrations WHERE version = ANY($1)",
      [[@version, @pinned_version]]
    )
  end

  defp migrated_version do
    case marker() do
      "pke_schema:" <> n -> String.to_integer(n)
      _ -> 0
    end
  end

  test "the module points core at this chain" do
    # If this ever returns nil, core's `mix phoenix_kit.update` silently skips
    # the module and no other test in the suite notices.
    assert Emails.migration_module() == Migrations
  end

  test "up/1 runs to completion inside a real migrator and stamps the marker" do
    reset()
    assert migrated_version() == 0

    assert :ok = run(:up, @version, UpMigration)

    assert marker() == "pke_schema:#{Migrations.current_version()}"
    assert migrated_version() == Migrations.current_version()
  end

  test "up/1 is idempotent through the migrator — a second full run changes nothing" do
    reset()
    assert :ok = run(:up, @version, UpMigration)
    run(:down, @version, UpMigration)

    assert :ok = run(:up, @version, UpMigration)
    assert migrated_version() == Migrations.current_version()
  end

  test "down/1 unstamps the marker and leaves every table and column standing" do
    reset()
    assert :ok = run(:up, @version, UpMigration)
    assert :ok = run(:down, @version, UpMigration)

    assert migrated_version() == 0

    for table <- Migrations.adopted_tables() do
      assert table_exists?(table), "down/1 removed #{table}"
    end

    # ...and the column this chain added survives a rollback too: re-running
    # up/1 would return the column, but never the attribution that was in it.
    assert column_exists?("phoenix_kit_email_logs", "integration_uuid")

    # Leave the database as the rest of the suite expects it.
    run(:up, @version, UpMigration)
  end

  test "up/1 with version: 0 does nothing at all" do
    reset()

    assert :ok = run(:up, @pinned_version, PinnedMigration)
    assert migrated_version() == 0

    run(:down, @pinned_version, PinnedMigration)
    run(:up, @version, UpMigration)
  end
end
