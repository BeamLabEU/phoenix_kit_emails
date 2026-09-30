defmodule PhoenixKit.Modules.Emails.TemplateExport do
  @moduledoc """
  Decides which stored templates become override files, and what those files
  are called.

  Message templates are moving from `phoenix_kit_email_templates` to files a
  host owns in its own repository. `plan/2` answers the two questions that
  migration turns on — *which rows carry an edit worth keeping*, and *what
  filename preserves the behaviour that row had* — as data, so
  `mix phoenix_kit_emails.templates.export` is left with nothing to do but
  write and report.

  ## Which rows

  | Row | Planned | Why |
  |---|---|---|
  | System template, edited | **yes** | the edit is the thing worth keeping |
  | System template, untouched | no | byte-identical to what this package ships; core supplies it now, translated |
  | Operator-authored (`is_system: false`) | no | newsletter layouts, authored at runtime — they keep a table and an editor |

  A template whose name this package does not ship counts as **edited**:
  nothing is known about what it should look like, and a file too many is
  recoverable where a dropped edit is not.

  ## Which filename

  The name becomes a directory and each part a file. The subtle part is the
  locale: a stored field is a language map, and `Template.get_translation/3`
  falls back through it, so one locale's content is what every recipient
  without their own translation actually receives. That locale must be written
  **without** a code in the filename, because a locale-less file is what core's
  resolution falls through to. Writing it as `subject.en.txt` would silently
  drop the operator's customization for every non-English recipient — the exact
  opposite of the point of exporting it.

  ## Raw-HTML variables in the `html` part

  `phoenix_kit_templates` from 0.2.0 onward escapes `{{var}}` values in an
  `html` part, and offers `{{{var}}}` (triple braces) as the opt-out for a
  variable, such as billing's `line_items_html`, whose value is already
  rendered HTML. `plan/3` rewrites the names `Template.raw_html_variables/0`
  lists into that triple-brace form when the host's loaded
  `phoenix_kit_templates` is new enough to understand it, and reports each
  file it touched. Below 0.2.0, that syntax is not understood at all — see
  `rewrite_raw_html/3` — so the file is written unchanged, with a notice
  saying it needs a manual edit once core (and `phoenix_kit_templates` with
  it) is upgraded. `subject` and `text` are never rewritten: they are always
  plain text there, so double and triple braces already behave identically.
  """

  alias PhoenixKit.Modules.Emails.Template

  @default_out "priv/phoenix_kit_templates"
  @raw_html_min_version "0.2.0"

  # Stored field -> {file stem, extension}. Only `html` is markup.
  @parts [{:subject, "subject", "txt"}, {:text_body, "text", "txt"}, {:html_body, "html", "html"}]

  # `phoenix_kit_templates` is an optional peer dependency (pulled in
  # transitively through `phoenix_kit`, not declared directly by this
  # package), so this cannot `alias` its `Substitution` module. The character
  # classes and whitespace handling below are copied from
  # `PhoenixKit.Templates.Substitution.variables/1`'s own pattern by design —
  # they must recognize exactly the placeholders that module would — not
  # invented independently.
  @placeholder ~r/
    \{\{\{\s*(?<triple>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}\}
    |
    \{\{\s*(?<double>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}
  /x

  @typedoc "What an export would do, without having done any of it."
  @type plan :: %{
          edited: [Template.t()],
          untouched: [Template.t()],
          authored: [Template.t()],
          files: [{Path.t(), String.t()}],
          notices: [String.t()]
        }

  @doc """
  Plans an export of `templates` against `shipped` (this package's own
  defaults, as `default_system_templates/0` returns them).

  Options:

    * `:out` — the target directory (default `#{@default_out}`).
    * `:raw_html_supported` — whether the `html` part may use `{{{var}}}` for
      a raw-HTML variable (see `rewrite_raw_html/3`). Defaults to detecting
      the loaded `phoenix_kit_templates` version; pass it explicitly to pin
      the behaviour regardless of what happens to be on the load path.
  """
  @spec plan([Template.t()], [map()], keyword()) :: plan()
  def plan(templates, shipped, opts \\ []) do
    out = Keyword.get(opts, :out, @default_out)
    raw_html_supported? = Keyword.get(opts, :raw_html_supported, default_raw_html_support?())
    by_name = Map.new(shipped, &{&1.name, &1})

    {system, authored} = Enum.split_with(templates, & &1.is_system)
    {edited, untouched} = Enum.split_with(system, &edited?(&1, by_name))

    {files, notices} =
      edited
      |> Enum.flat_map(&files_for(&1, out))
      |> Enum.map_reduce([], &rewrite_html_file(&1, &2, raw_html_supported?))

    %{
      edited: edited,
      untouched: untouched,
      authored: authored,
      files: files,
      notices: notices
    }
  end

  @doc """
  Whether `template` still matches what this package ships under its name.

  Compares the three content fields only — a slug, a usage count or a
  timestamp differing does not make a template customized.
  """
  @spec edited?(Template.t(), %{optional(String.t()) => map()}) :: boolean()
  def edited?(%Template{} = template, by_name) do
    case Map.get(by_name, template.name) do
      nil ->
        true

      default ->
        Enum.any?(@parts, fn {field, _stem, _ext} ->
          Map.get(template, field) != Map.get(default, field)
        end)
    end
  end

  @doc """
  The `{path, content}` pairs one template exports to.

  Empty and non-string values are skipped: a part a template does not supply
  is absent, not an empty file.
  """
  @spec files_for(Template.t(), Path.t()) :: [{Path.t(), String.t()}]
  def files_for(%Template{} = template, out \\ @default_out) do
    Enum.flat_map(@parts, fn {field, stem, extension} ->
      case Map.get(template, field) do
        map when is_map(map) -> part_files(map, template.name, stem, extension, out)
        _other -> []
      end
    end)
  end

  @doc """
  Writes planned `{path, content}` pairs, returning `{path, outcome}` for each.

  Outcomes are `:written`, `:would_write` (under `dry_run: true`) and
  `:skipped` — a path that already exists is **refused** unless `force: true`.
  That refusal is the point: a re-run, or an export onto a host that has
  already hand-written an override, must never silently replace a file a human
  wrote. Nothing here deletes.
  """
  @spec write_files([{Path.t(), String.t()}], keyword()) ::
          [{Path.t(), :written | :would_write | :skipped}]
  def write_files(files, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)

    Enum.map(files, fn {path, content} ->
      cond do
        File.exists?(path) and not force? ->
          {path, :skipped}

        dry_run? ->
          {path, :would_write}

        true ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          {path, :written}
      end
    end)
  end

  defp part_files(field_map, name, stem, extension, out) do
    fallback = fallback_locale(field_map)

    for {locale, content} <- Enum.sort(field_map), is_binary(content), content != "" do
      suffix = if locale == fallback, do: "", else: ".#{locale}"
      {Path.join([out, name, "#{stem}#{suffix}.#{extension}"]), content}
    end
  end

  @doc """
  The locale every recipient falls through to: `"en"` when the map has it —
  the key `Template.get_translation/3` itself defaults to — otherwise the
  lowest-sorting one, so the choice is deterministic rather than whatever the
  map happens to yield first.
  """
  @spec fallback_locale(map()) :: String.t() | nil
  def fallback_locale(field_map) when is_map(field_map) do
    keys = field_map |> Map.keys() |> Enum.filter(&is_binary/1)

    cond do
      "en" in keys -> "en"
      keys == [] -> nil
      true -> Enum.min(keys)
    end
  end

  @doc """
  Rewrites `Template.raw_html_variables/0` names in an `html` part from
  `{{var}}` to `{{{var}}}`, when `raw_html_supported?` is true — the escaping
  opt-out `phoenix_kit_templates` understands from 0.2.0 onward. Below that
  version the package's own `Substitution` only understands `{{var}}` and
  treats a triple brace as literal braces around a substituted double pair
  (see that module's moduledoc), so nothing is rewritten and a notice says why.

  An already-triple-braced placeholder is left alone — this is what keeps the
  rewrite idempotent across repeated exports. A `{{..._html}}` placeholder
  that is *not* on `raw_html_variables/0` is also left alone, but reported: a
  new pre-rendered-HTML variable must be added to that list before an export
  can safely convert it, so silently leaving it as `{{var}}` (still correct
  under `phoenix_kit_templates` < 0.2.0, still wrong under `escape: true` at
  0.2.0+) needs a human to notice.

  `path` is only used to prefix the returned notices.
  """
  @spec rewrite_raw_html(String.t(), Path.t(), boolean()) :: {String.t(), [String.t()]}
  def rewrite_raw_html(content, path, raw_html_supported?) when is_binary(content) do
    known = Template.raw_html_variables()

    double_html_names =
      @placeholder
      |> Regex.scan(content, capture: :all_names)
      |> Enum.flat_map(fn
        [double, ""] when double != "" -> [double]
        [_double, _triple] -> []
      end)
      |> Enum.filter(&String.ends_with?(&1, "_html"))
      |> Enum.uniq()

    {known_names, unknown_names} = Enum.split_with(double_html_names, &(&1 in known))

    new_content =
      if raw_html_supported? and known_names != [] do
        Regex.replace(@placeholder, content, fn full, triple, double ->
          cond do
            triple != "" -> full
            double in known_names -> "{{{#{double}}}}"
            true -> full
          end
        end)
      else
        content
      end

    {new_content, notices(path, known_names, unknown_names, raw_html_supported?)}
  end

  defp notices(path, known_names, unknown_names, raw_html_supported?) do
    Enum.map(known_names, fn name ->
      if raw_html_supported? do
        "#{path}: rewrote {{#{name}}} to {{{#{name}}}} (already-rendered HTML)"
      else
        "#{path}: {{#{name}}} holds already-rendered HTML but the loaded " <>
          "phoenix_kit_templates does not support {{{...}}} yet — after " <>
          "upgrading core to >= 2.40 (phoenix_kit_templates ~> 0.2.0), " <>
          "replace {{#{name}}} with {{{#{name}}}} in this file"
      end
    end) ++
      Enum.map(unknown_names, fn name ->
        "#{path}: unknown raw-HTML placeholder {{#{name}}} — left as-is; " <>
          "add it to Template.raw_html_variables/0 if its value is already-rendered HTML"
      end)
  end

  defp rewrite_html_file({path, content}, notices, raw_html_supported?) do
    if String.ends_with?(path, ".html") do
      {new_content, file_notices} = rewrite_raw_html(content, path, raw_html_supported?)
      {{path, new_content}, notices ++ file_notices}
    else
      {{path, content}, notices}
    end
  end

  defp default_raw_html_support? do
    case Application.spec(:phoenix_kit_templates, :vsn) do
      nil ->
        _ = Application.load(:phoenix_kit_templates)
        raw_html_support?(Application.spec(:phoenix_kit_templates, :vsn))

      vsn ->
        raw_html_support?(vsn)
    end
  end

  defp raw_html_support?(nil), do: false

  defp raw_html_support?(vsn) do
    vsn |> to_string() |> Version.match?(">= #{@raw_html_min_version}")
  rescue
    Version.InvalidVersionError -> false
  end
end
