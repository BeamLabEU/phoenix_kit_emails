defmodule PhoenixKit.Modules.Emails.MigrationsTest do
  @moduledoc """
  Ownership contract for this package's migration chain. `up_statements/1`
  and `down_statements/2` are the testable data form of what `up/1` and
  `down/1` execute, so these assertions run without a database.

  The point of the file is the destructive-statement pin:
  `phoenix_kit_email_logs` is a CORE-owned table this chain only extends,
  and nothing this module can emit may drop it — the exact trap
  `phoenix_kit_legal`'s own chain documents having been one repaired
  version marker away from springing.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Migrations

  test "current_version/0 is a positive integer and the marker table is the logs table" do
    assert is_integer(Migrations.current_version())
    assert Migrations.current_version() > 0
    assert Migrations.version_table() == "phoenix_kit_email_logs"
  end

  test "up adds the attribution column and its index, and stamps the version marker" do
    statements = Migrations.up_statements()

    assert Enum.any?(statements, &(&1 =~ ~r/ADD COLUMN IF NOT EXISTS "integration_uuid" uuid/))
    assert Enum.any?(statements, &(&1 =~ "CREATE INDEX IF NOT EXISTS"))

    assert Enum.any?(
             statements,
             &(&1 =~
                 "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:#{Migrations.current_version()}'")
           )
  end

  test "every up statement is idempotent" do
    for statement <- Migrations.up_statements() do
      assert statement =~ "IF NOT EXISTS" or statement =~ "COMMENT ON",
             "non-idempotent statement: #{statement}"
    end
  end

  test "nothing this chain emits can drop the core-owned table or the column" do
    statements = Migrations.up_statements() ++ Migrations.down_statements()

    for statement <- statements do
      refute statement =~ ~r/\bDROP\b/i, "destructive statement: #{statement}"
    end
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) == [
             "COMMENT ON TABLE public.phoenix_kit_email_logs IS NULL"
           ]

    assert Migrations.down_statements("public", 1) == [
             "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:1'"
           ]
  end

  test "the schema prefix is validated before it reaches the DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP TABLE x") end
  end

  test "a custom prefix is applied to every statement that names the table" do
    for statement <- Migrations.up_statements("tenant_a") do
      assert statement =~ "tenant_a.phoenix_kit_email_logs"
    end
  end
end
