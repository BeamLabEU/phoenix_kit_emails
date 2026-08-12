defmodule PhoenixKit.Modules.Emails.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_emails` — the
  decentralized-migrations protocol core's `mix phoenix_kit.update`
  discovers via `c:PhoenixKit.Module.migration_module/0`:
  `current_version/0` + `migrated_version_runtime/1` + idempotent `up/1` +
  version-aware `down/1`. `PhoenixKit.Modules.Legal.Migrations` is the
  reference implementation this chain is shaped after — same situation
  (a core-created table whose FUTURE shape moves here), same
  `COMMENT`-marker version tracking.

  ## Ownership

  `phoenix_kit_email_logs` and `phoenix_kit_email_events` are created by
  core's squashed baseline and stay core-owned: this chain NEVER creates,
  alters the shape of, or drops those tables' core columns. It only ADDS
  module-specific columns core's manifest does not know about — core's
  `PhoenixKit.Migrations.ExpectedSchema` audit reports such a column as an
  `:info`-level "extra column, not in the manifest" finding, never a
  failure, which is precisely the affordance that makes this safe without
  a coordinated core release.

  ## V1 — `integration_uuid` attribution

  Adds a nullable `integration_uuid` (uuid) column plus an index to
  `phoenix_kit_email_logs`. Before it, a log recorded only the provider
  *kind* (`"aws_ses"`, `"brevo_api"`), so with several accounts of the same
  kind configured there was no way to tell WHICH account sent a message —
  which is what per-account event tracking needs (see
  `PhoenixKit.Modules.Emails.AwsIntegrations`). Nullable because every
  pre-existing row genuinely has no known account, and because the stamp is
  best-effort on the send path (see
  `PhoenixKit.Modules.Emails.Interceptor`): an unstamped row must remain a
  valid row, not a constraint violation.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops the table and never
  drops the column. The table is core-owned and carries the delivery
  history; the column may already hold attribution an operator relies on,
  and re-running `up/1` after a rollback would silently return an
  all-`NULL` column rather than the data. Rolling the MODULE back must not
  destroy either.

  The migrated version is tracked as a `pke_schema:<N>` `COMMENT` on
  `phoenix_kit_email_logs` (the marker convention from the legal/projects
  chains, namespaced for this package). A marker-less table reads as
  version 0 — the core-baseline shape from before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pke_schema:"
  @version_table "phoenix_kit_email_logs"

  @doc "The chain version this code needs."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pke_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pke_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0`.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the convention the
    # legal chain inherited from the projects chain).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    opts
    |> validated_prefix()
    |> up_statements()
    |> Enum.each(&execute/1)
  end

  @doc """
  Rolls back to `target` (`:version` in `opts`). Never drops the table or
  the column — see the moduledoc.
  """
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS`), so the chain can be re-run
  against a database at any version without a pre-flight check.
  """
  @spec up_statements(String.t()) :: [String.t()]
  def up_statements(prefix \\ "public") do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    [
      "ALTER TABLE #{p}#{@version_table} ADD COLUMN IF NOT EXISTS \"integration_uuid\" uuid",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_integration_uuid_idx " <>
        "ON #{p}#{@version_table} USING btree (integration_uuid)",
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{@current_version}'"
    ]
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0) do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the legal chain uses.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
