defmodule PhoenixKit.Modules.Emails.Utils.Json do
  @moduledoc """
  Thin helper around Elixir's built-in `JSON` module (1.18+) for the one
  thing it doesn't provide: pretty-printing.

  This module's own code uses the built-in `JSON` module directly for plain
  encode/decode — this exists only for the handful of call sites (JSON
  offered to an admin as a downloadable export) that need indented output.

  Mirrors `PhoenixKit.Utils.Json` from core (phoenix_kit) — duplicated here
  because that helper isn't in the currently-published core version this
  project depends on. Safe to delete and delegate to core's version once a
  release with it is available.
  """

  @doc """
  Encodes `term` as indented, human-readable JSON (2-space indent).

  `term` is encoded via `JSON.encode!/1` and decoded back first, so structs
  (e.g. Ecto schemas with `@derive {JSON.Encoder, ...}`) go through the
  `JSON.Encoder` protocol correctly — the recursive pretty-printer below
  only ever walks plain maps/lists/primitives, never a raw struct (which
  doesn't implement `Enumerable`).

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.Json.encode_pretty!(%{"a" => 1})
      ~s({\\n  "a": 1\\n})
  """
  @spec encode_pretty!(term()) :: String.t()
  def encode_pretty!(term) do
    term
    |> JSON.encode!()
    |> JSON.decode!()
    |> pretty(0)
    |> IO.iodata_to_binary()
  end

  defp pretty(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp pretty(map, indent) when is_map(map) do
    inner_indent = indent + 2

    entries =
      map
      |> Enum.map(fn {key, value} ->
        [indent_of(inner_indent), JSON.encode!(to_string(key)), ": ", pretty(value, inner_indent)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", entries, "\n", indent_of(indent), "}"]
  end

  defp pretty([], _indent), do: "[]"

  defp pretty(list, indent) when is_list(list) do
    inner_indent = indent + 2

    entries =
      list
      |> Enum.map(fn value -> [indent_of(inner_indent), pretty(value, inner_indent)] end)
      |> Enum.intersperse(",\n")

    ["[\n", entries, "\n", indent_of(indent), "]"]
  end

  defp pretty(value, _indent), do: JSON.encode!(value)

  defp indent_of(n), do: String.duplicate(" ", n)
end
