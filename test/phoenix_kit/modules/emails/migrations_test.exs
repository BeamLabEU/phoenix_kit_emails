defmodule PhoenixKit.Modules.Emails.MigrationsTest do
  @moduledoc """
  Ownership contract for this package's migration chain. `up_statements/1`
  and `down_statements/2` are the testable data form of what `up/1` and
  `down/1` execute, so most of this runs without a database.

  Two things it exists to pin:

    * **Nothing here can destroy data.** These tables are core-created on
      every install that exists today and hold the delivery history, so no
      statement this module can emit may contain `DROP` — the exact trap
      `phoenix_kit_legal`'s own chain documents having been one repaired
      version marker away from springing.
    * **The adopted DDL does not drift from core's.** V1 is an adoption
      step (see the module's moduledoc): every adopted statement must be
      byte-identical to what core's `ExpectedSchema` manifest declares for
      the same object, or a fresh install would end up with a shape core's
      auditor calls drifted.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Modules.Emails.Migrations

  @adopted_tables ~w(
    phoenix_kit_email_logs
    phoenix_kit_email_events
    phoenix_kit_email_blocklist
    phoenix_kit_email_templates
    phoenix_kit_email_metrics
    phoenix_kit_email_orphaned_events
  )

  describe "chain protocol" do
    test "current_version/0 is a positive integer and the marker table is the logs table" do
      assert is_integer(Migrations.current_version())
      assert Migrations.current_version() > 0
      assert Migrations.version_table() == "phoenix_kit_email_logs"
    end

    test "up stamps the version marker" do
      assert Enum.any?(
               Migrations.up_statements(),
               &(&1 ==
                   "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:#{Migrations.current_version()}'")
             )
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
      assert_raise ArgumentError, fn -> Migrations.down_statements("public; DROP TABLE x") end
    end
  end

  describe "adoption" do
    test "every table this package owns is created" do
      for table <- @adopted_tables do
        assert create_table_statement(table),
               "no CREATE TABLE for #{table}"
      end

      assert Enum.sort(Migrations.adopted_tables()) == Enum.sort(@adopted_tables)
    end

    test "CREATE TABLE carries core's full column list, NOT NULLs included" do
      # The regression this pins: building the table from the manifest's
      # repair DDL alone (`CREATE TABLE ... ()` + `ADD COLUMN IF NOT
      # EXISTS`) silently drops NOT NULL from every column without a
      # default — 26 of them — because adding such a column to a populated
      # table is impossible. A fresh install must still get core's shape.
      %{columns: columns} = Migrations.adopted_objects()

      for table <- @adopted_tables do
        statement = create_table_statement(table)
        table_columns = Enum.filter(columns, fn {t, _pos, _def, _nn} -> t == table end)

        assert table_columns != []

        for {_t, _pos, raw_definition, not_null} <- table_columns do
          # adopted_objects/0 is the RAW data, still carrying core's
          # `__SCHEMA__` token; up_statements/1 has resolved it.
          definition = String.replace(raw_definition, "__SCHEMA__", "public")

          assert String.contains?(statement, definition),
                 "#{table} is missing column #{definition}"

          if not_null do
            expected =
              if String.ends_with?(definition, " NOT NULL"),
                do: definition,
                else: definition <> " NOT NULL"

            assert String.contains?(statement, expected),
                   "#{table}.#{definition} lost its NOT NULL"
          end
        end
      end
    end

    test "our own columns are added on top of the table, not folded into it" do
      # CREATE TABLE is "the table core would have created"; everything this
      # chain adds is a separate, additive statement.
      refute String.contains?(
               create_table_statement("phoenix_kit_email_logs"),
               "integration_uuid"
             )
    end

    test "phoenix_kit_email_send_profiles is NOT adopted — core owns and uses it" do
      refute "phoenix_kit_email_send_profiles" in Migrations.adopted_tables()

      refute Enum.any?(
               Migrations.up_statements(),
               &String.contains?(&1, "phoenix_kit_email_send_profiles")
             )
    end

    test "each adopted table gets its uuid column, primary key and unique uuid index" do
      statements = Migrations.up_statements()

      for table <- @adopted_tables do
        assert Enum.any?(
                 statements,
                 &(&1 ==
                     "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS " <>
                       "\"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL")
               ),
               "no uuid column for #{table}"

        assert Enum.any?(statements, fn statement ->
                 String.contains?(statement, "ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid)")
               end),
               "no primary key for #{table}"
      end
    end

    test "the events -> logs foreign key is emitted after both primary keys" do
      statements = Migrations.up_statements()

      fk_index =
        Enum.find_index(statements, &String.contains?(&1, "fk_email_events_email_log_uuid"))

      logs_pkey_index =
        Enum.find_index(
          statements,
          &String.contains?(&1, "ADD CONSTRAINT phoenix_kit_email_logs_pkey")
        )

      assert is_integer(fk_index) and is_integer(logs_pkey_index)

      # The FK references phoenix_kit_email_logs(uuid), which needs the
      # primary key to already exist.
      assert logs_pkey_index < fk_index
    end

    test "the healing ADD COLUMN statements come after their table is created" do
      statements = Migrations.up_statements()

      for table <- @adopted_tables do
        create_index =
          Enum.find_index(
            statements,
            &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
          )

        first_column_index =
          Enum.find_index(
            statements,
            &String.starts_with?(&1, "ALTER TABLE public.#{table} ADD COLUMN")
          )

        assert create_index < first_column_index, "columns precede CREATE TABLE for #{table}"
      end
    end

    test "V1's own shape change: the integration_uuid column and its index" do
      statements = Migrations.up_statements()

      assert "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"integration_uuid\" uuid" in statements

      assert Enum.any?(
               statements,
               &String.contains?(&1, "phoenix_kit_email_logs_integration_uuid_idx")
             )
    end
  end

  describe "safety" do
    test "nothing this chain emits can drop a table or a column" do
      statements = Migrations.up_statements() ++ Migrations.down_statements()

      for statement <- statements do
        refute statement =~ ~r/\bDROP\b/i, "destructive statement: #{statement}"
      end
    end

    test "every statement is idempotent" do
      for statement <- Migrations.up_statements() do
        assert statement =~ "IF NOT EXISTS" or statement =~ "COMMENT ON",
               "non-idempotent statement: #{statement}"
      end
    end

    test "up_statements/1 is pure — repeated calls produce the identical list" do
      assert Migrations.up_statements() == Migrations.up_statements()
    end

    test "a custom prefix is applied to every reference to one of our tables" do
      for statement <- Migrations.up_statements("tenant_a") do
        refute statement =~ ~r/\bpublic\.phoenix_kit_email/,
               "statement leaked the public schema: #{statement}"
      end

      # ...and to the schema-qualified helpers our own DDL calls.
      refute Enum.any?(
               Migrations.up_statements("tenant_a"),
               &String.contains?(&1, "public.uuid_generate_v7()")
             )

      # `public.gin_trgm_ops` is NOT a leak and must stay: an operator
      # class lives in the schema its EXTENSION was installed into
      # (core installs pg_trgm in public), not in the install's own
      # schema. Core's manifest hard-codes it for the same reason, and
      # rewriting it to the prefix would make the index uncreatable.
      assert Enum.any?(
               Migrations.up_statements("tenant_a"),
               &String.contains?(&1, "public.gin_trgm_ops")
             )
    end

    test "the prefix-embedded index name is resolved, not left as a marker" do
      # Core embeds the prefix in a handful of index NAMES (bare on public,
      # "<prefix>_" elsewhere). Emitting the raw marker would create a
      # second, differently-named index on every non-public install.
      for prefix <- ["public", "tenant_a"] do
        refute Enum.any?(
                 Migrations.up_statements(prefix),
                 &String.contains?(&1, "__PK_NAME_EXEMPT__")
               )
      end

      assert Enum.any?(
               Migrations.up_statements("public"),
               &(&1 =~ ~r/CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_templates_uuid_idx /)
             )

      assert Enum.any?(
               Migrations.up_statements("tenant_a"),
               &(&1 =~
                   ~r/CREATE UNIQUE INDEX IF NOT EXISTS tenant_a_phoenix_kit_email_templates_uuid_idx /)
             )
    end
  end

  describe "conformance with core's ExpectedSchema manifest" do
    # V1 adopts core-created objects, so the adopted statements must match
    # what core itself would emit — byte for byte, for any prefix. This is
    # what stops the drift class that gave phoenix_kit_legal three
    # disagreeing DDL copies of one table.
    #
    # Deliberately SKIPS objects the manifest no longer declares: the whole
    # point of this chain is that a future core release stops shipping
    # them, and that release must not be blocked by its own success. What
    # is asserted is "for every adopted object core still knows about, we
    # agree with core".

    setup do
      unless Code.ensure_loaded?(ExpectedSchema) do
        raise "core's ExpectedSchema is unavailable — this test needs it"
      end

      :ok
    end

    for prefix <- ["public", "tenant_a"] do
      test "adopted statements match core's manifest under prefix #{prefix}" do
        prefix = unquote(prefix)
        ours = MapSet.new(Migrations.up_statements(prefix))

        core_objects =
          ExpectedSchema.objects(prefix)
          # `:table` is the one declared departure — see the module's
          # `table_statements/0`. Its column list is checked separately,
          # against the same manifest data, by the "CREATE TABLE carries
          # core's full column list" test above.
          |> Enum.filter(&(is_binary(&1.create) and &1.class != :table and adopted_object?(&1)))

        # Sanity: if this ever hits zero the filter broke, and the whole
        # describe block would pass vacuously.
        assert length(core_objects) > 100

        mismatched =
          core_objects
          |> Enum.reject(&MapSet.member?(ours, &1.create))
          |> Enum.map(& &1.id)

        assert mismatched == [],
               "these core objects are not emitted byte-identically: #{inspect(mismatched)}"
      end
    end

    test "the only statements we emit beyond core's manifest are our own" do
      core =
        ExpectedSchema.objects("public")
        |> Enum.filter(&is_binary(&1.create))
        |> MapSet.new(& &1.create)

      extra =
        Enum.reject(
          Migrations.up_statements(),
          &(String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS") or MapSet.member?(core, &1))
        )

      assert Enum.sort(extra) == [
               "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"integration_uuid\" uuid",
               "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:1'",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_integration_uuid_idx ON public.phoenix_kit_email_logs USING btree (integration_uuid)"
             ]
    end

    defp adopted_object?(object) do
      Enum.any?(@adopted_tables, fn table ->
        String.starts_with?(object.id, "table:" <> table) or
          String.starts_with?(object.id, "column:" <> table <> ".") or
          String.starts_with?(object.id, "constraint:" <> table <> ".") or
          (object.class == :index and
             match?(%{table: ^table}, elem(List.last(object.revisions), 1)))
      end)
    end
  end

  defp create_table_statement(table) do
    Enum.find(
      Migrations.up_statements(),
      &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
    )
  end
end
