defmodule PhoenixKit.Modules.Emails.TemplateExport.Body do
  @moduledoc """
  Turns a stored full-document `html_body` into the *body fragment* an
  `html.html` override file should hold.

  Core wraps every email built from a file in a shared layout (header, footer,
  branding — see `PhoenixKit.Email.Layout`) and never wraps a part that is
  already a whole document. A seeded row is a whole document, so exporting it
  verbatim keeps the old chrome forever and the host never gets the shared one.
  `extract/2` cuts the chrome off.

  ## Where the body is, in the shipped seeds

  All nine seeds put a `.header` block and a `.footer` block inside one
  container, and the body *between* them. Only five of the nine wrap that body
  in `.content`; the four auth templates (`magic_link`, `register`,
  `reset_password`, `update_email`) — the rows hosts actually edit — have the
  body directly between the two blocks. So the cut is made on the **boundary**:
  everything after the end of the `.header` element and before the start of the
  `.footer` element. A lone `.content` wrapper around that region is unwrapped,
  because the layout owns the padding.

  ## What is kept of the header and footer, and why

  The seeds' `.header` and `.footer` are not pure chrome — dropping them whole
  would lose text a host translated and edited:

    * the `.header` holds the email's **title** (`<h1>Password Reset Request</h1>`,
      billing's `INVOICE` + number). A header with a heading in it is kept as the
      first block of the body — its heading and whatever sits with it, without
      the header's own background and colour — and one without a heading is
      treated as chrome and dropped;
    * the `.footer` holds the fallback link under a button (`{{reset_url}}`) and
      billing's company details (`{{company_name}}`, VAT). A footer containing a
      placeholder is kept as the last block of the body; one without any is
      treated as chrome and dropped.

  Anything dropped that held text is reported, so the operator can move it into
  the host's `_header`/`_footer` override.

  ## Styles

  The `<style>` block goes with the `<head>`, and with it every class the body
  relies on (`.button`, `.warning`, billing's tables). So the rules are
  **inlined**: each element in the fragment gets the declarations of the
  matching simple rules in its `style` attribute, with an existing inline
  `style` winning. Supported selectors are `tag`, `.class`, `tag.class` and
  descendant chains of them; anything else (`:hover`, `>`, ids, `@media`) is
  skipped — it was never reliable in email clients.

  With `accent: true` the default blue of a `.button` becomes
  `{{accent_color}}` (a variable core's layout provides from 2.44). Other
  colours — the red of a password reset, the green of an email change — carry
  meaning and are kept.

  ## When it falls back

  If the `.header`/`.footer` pair cannot be found as siblings (a host replaced
  the shell), `extract/2` returns everything inside `<body>`, still with the
  styles inlined, and says so. It never guesses a cut.

  No HTML parser is used: the structure is known, and all that is needed is a
  tag tokenizer with balanced-element search. The tokenizer keeps every byte it
  does not rewrite, so a host's edits come through untouched.
  """

  @type note :: {:body_fallback | :chrome_dropped, [String.t()]}

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  # Tags whose nesting is checked when deciding that the header and footer are
  # siblings. `p`, `li` and friends may legally be left unclosed, so they are
  # not part of it.
  @strict ~w(div table thead tbody tfoot tr td th ul ol section article span a strong
             em b i u h1 h2 h3 h4 h5 h6 blockquote pre center font)

  @headings ~w(h1 h2 h3 h4 h5 h6)

  # The only declarations of a retained header's own box that make sense once
  # its background and colour are gone.
  @header_props ~w(text-align margin margin-top margin-bottom)

  @default_blues ~w(#3b82f6 #2563eb)

  @doc """
  Whether `html` is a whole document — the test core's own layout applies:
  after a BOM, whitespace, comments and an `<?xml ?>` prolog, `<!doctype` or an
  `<html` tag.
  """
  @spec document?(String.t()) :: boolean()
  def document?(html) when is_binary(html) do
    html |> skip_prolog() |> document_start?()
  end

  defp skip_prolog(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: skip_prolog(rest)
  defp skip_prolog(<<c, rest::binary>>) when c in ~c" \t\r\n", do: skip_prolog(rest)

  defp skip_prolog(<<"<!--", rest::binary>> = html) do
    case :binary.match(rest, "-->") do
      {at, 3} -> skip_prolog(binary_part(rest, at + 3, byte_size(rest) - at - 3))
      :nomatch -> html
    end
  end

  defp skip_prolog(<<"<?xml", rest::binary>> = html) do
    case :binary.match(rest, "?>") do
      {at, 2} -> skip_prolog(binary_part(rest, at + 2, byte_size(rest) - at - 2))
      :nomatch -> html
    end
  end

  defp skip_prolog(html), do: html

  defp document_start?(html) do
    lower = html |> :binary.part(0, min(byte_size(html), 16)) |> String.downcase(:ascii)
    String.starts_with?(lower, "<!doctype") or Regex.match?(~r/\A<html[\s>\/]/, lower)
  end

  @doc """
  Extracts the body fragment of `html`.

  Returns `{fragment, notes}`. A `html` that is not a whole document comes back
  unchanged with no notes. `notes` is a list of `{kind, texts}`:

    * `{:body_fallback, [reason]}` — the header/footer pair was not found as
      siblings, so the whole `<body>` was kept;
    * `{:chrome_dropped, ["header: …", "footer: …"]}` — chrome that held text
      and was left out.

  Options: `:accent` (default `false`), see the moduledoc.
  """
  @spec extract(String.t(), keyword()) :: {String.t(), [note()]}
  def extract(html, opts \\ []) when is_binary(html) do
    if document?(html) do
      do_extract(html, Keyword.get(opts, :accent, false))
    else
      {html, []}
    end
  end

  defp do_extract(html, accent?) do
    tokens = html |> tokenize() |> Enum.with_index()
    rules = tokens |> Enum.map(&elem(&1, 0)) |> style_rules()
    {first, last} = body_range(tokens)
    inner = Enum.slice(tokens, first..last//1)

    case boundary(inner) do
      {:ok, header, footer} ->
        inner |> pieces(header, footer) |> assemble(tokens, rules, accent?)

      {:error, reason} ->
        fragment = inner |> render(tokens, rules, accent?) |> tidy()
        {fragment, [{:body_fallback, [reason]}]}
    end
  end

  # ── tokenizer ─────────────────────────────────────────────────────────

  # Tokens: {:text, s} | {:comment, s} | {:decl, s} |
  #         {:open, name, attrs, raw} | {:void, name, attrs, raw} | {:close, name, raw}
  # `attrs` is everything between the name and the closing `>`.
  defp tokenize(html), do: tokenize(html, [])

  defp tokenize(<<>>, acc), do: Enum.reverse(acc)

  defp tokenize(<<"<!--", rest::binary>> = html, acc) do
    case :binary.match(rest, "-->") do
      {at, 3} ->
        len = at + 3
        <<comment::binary-size(len), tail::binary>> = rest
        tokenize(tail, [{:comment, "<!--" <> comment} | acc])

      :nomatch ->
        tokenize_text(html, acc)
    end
  end

  defp tokenize(<<"<!", rest::binary>> = html, acc) do
    case :binary.match(rest, ">") do
      {at, 1} ->
        <<decl::binary-size(at), ">", tail::binary>> = rest
        tokenize(tail, [{:decl, "<!" <> decl <> ">"} | acc])

      :nomatch ->
        tokenize_text(html, acc)
    end
  end

  defp tokenize(<<"</", c, _::binary>> = html, acc) when c in ?a..?z or c in ?A..?Z do
    <<"</", rest::binary>> = html

    case :binary.match(rest, ">") do
      {at, 1} ->
        <<inner::binary-size(at), ">", tail::binary>> = rest
        name = inner |> String.trim() |> String.downcase()
        tokenize(tail, [{:close, name, "</" <> inner <> ">"} | acc])

      :nomatch ->
        tokenize_text(html, acc)
    end
  end

  defp tokenize(<<"<", c, _::binary>> = html, acc) when c in ?a..?z or c in ?A..?Z do
    <<"<", rest::binary>> = html

    with {name, after_name} <- take_name(rest),
         {attrs, tail} <- take_attrs(after_name, nil, []) do
      lname = String.downcase(name)
      raw = "<" <> name <> attrs <> ">"
      self_closing? = String.ends_with?(String.trim_trailing(attrs), "/")
      kind = if lname in @void or self_closing?, do: :void, else: :open
      acc = [{kind, lname, attrs, raw} | acc]

      if kind == :open and lname in ~w(style script) do
        {body, tail} = take_raw_text(tail, lname)
        tokenize(tail, [{:text, body} | acc])
      else
        tokenize(tail, acc)
      end
    else
      _ -> tokenize_text(html, acc)
    end
  end

  defp tokenize(html, acc), do: tokenize_text(html, acc)

  # One byte is always consumed, so a stray `<` cannot loop.
  defp tokenize_text(<<c, rest::binary>>, acc) do
    {text, tail} =
      case :binary.match(rest, "<") do
        {at, 1} -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
        :nomatch -> {rest, <<>>}
      end

    case acc do
      [{:text, prev} | acc_tail] -> tokenize(tail, [{:text, prev <> <<c>> <> text} | acc_tail])
      _ -> tokenize(tail, [{:text, <<c>> <> text} | acc])
    end
  end

  defp take_name(bin) do
    len = name_length(bin, 0)
    {binary_part(bin, 0, len), binary_part(bin, len, byte_size(bin) - len)}
  end

  defp name_length(<<c, rest::binary>>, n)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-:_",
       do: name_length(rest, n + 1)

  defp name_length(_rest, n), do: n

  # Up to the first `>` that is not inside a quoted attribute value.
  defp take_attrs(<<>>, _quote, _acc), do: :error

  defp take_attrs(<<">", rest::binary>>, nil, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_attrs(<<q, rest::binary>>, nil, acc) when q in ~c"\"'",
    do: take_attrs(rest, q, [<<q>> | acc])

  defp take_attrs(<<q, rest::binary>>, q, acc), do: take_attrs(rest, nil, [<<q>> | acc])
  defp take_attrs(<<c, rest::binary>>, quote, acc), do: take_attrs(rest, quote, [<<c>> | acc])

  defp take_raw_text(bin, name) do
    lower = String.downcase(bin)

    case :binary.match(lower, "</" <> name) do
      {at, _} -> {binary_part(bin, 0, at), binary_part(bin, at, byte_size(bin) - at)}
      :nomatch -> {bin, <<>>}
    end
  end

  # ── structure ─────────────────────────────────────────────────────────

  # Index range of what is inside <body>; with no body, after </head>.
  defp body_range(tokens) do
    last_index = length(tokens) - 1

    first =
      case Enum.find(tokens, &open?(&1, "body")) do
        {_, i} -> i + 1
        nil -> head_end(tokens)
      end

    last =
      case tokens |> Enum.reverse() |> Enum.find(&close?(&1, "body")) do
        {_, i} -> i - 1
        nil -> closing_html(tokens, last_index)
      end

    {first, last}
  end

  defp head_end(tokens) do
    case Enum.find(tokens, &close?(&1, "head")) do
      {_, i} -> i + 1
      nil -> 0
    end
  end

  defp closing_html(tokens, last_index) do
    case tokens |> Enum.reverse() |> Enum.find(&close?(&1, "html")) do
      {_, i} -> i - 1
      nil -> last_index
    end
  end

  defp open?({{:open, name, _, _}, _}, name), do: true
  defp open?(_, _), do: false
  defp close?({{:close, name, _}, _}, name), do: true
  defp close?(_, _), do: false

  # The header and footer as {open_index, close_index} pairs, only when both
  # exist and the region between them is balanced, i.e. they are siblings.
  defp boundary(inner) do
    with {:header, {:ok, header}} <- {:header, element_with_class(inner, "header", 0)},
         {:footer, {:ok, footer}} <-
           {:footer, element_with_class(inner, "footer", elem(header, 1))},
         true <- balanced?(inner, elem(header, 1) + 1, elem(footer, 0) - 1) do
      {:ok, header, footer}
    else
      {:header, :error} -> {:error, "no .header element found"}
      {:footer, :error} -> {:error, "no .footer element found after the .header"}
      false -> {:error, "the .header and .footer are not siblings"}
    end
  end

  # {open_index, close_index} (absolute token indexes) of the first element
  # carrying `class`, searching from absolute index `from`.
  defp element_with_class(inner, class, from) do
    found =
      Enum.find(inner, fn
        {{:open, _name, attrs, _raw}, i} -> i >= from and class in classes(attrs)
        _ -> false
      end)

    case found do
      {{:open, name, _, _}, i} ->
        case matching_close(inner, i, name) do
          nil -> :error
          j -> {:ok, {i, j}}
        end

      nil ->
        :error
    end
  end

  defp matching_close(inner, open_index, name) do
    inner
    |> Enum.filter(fn {_, i} -> i > open_index end)
    |> Enum.reduce_while(1, fn
      {{:open, ^name, _, _}, _}, depth ->
        {:cont, depth + 1}

      {{:close, ^name, _}, i}, 1 ->
        {:halt, {:found, i}}

      {{:close, ^name, _}, _}, depth ->
        {:cont, depth - 1}

      _, depth ->
        {:cont, depth}
    end)
    |> case do
      {:found, i} -> i
      _ -> nil
    end
  end

  # Strict tags opened and closed in [from, to] must net to zero without ever
  # closing something this region did not open.
  defp balanced?(inner, from, to) do
    result =
      inner
      |> Enum.filter(fn {_, i} -> i >= from and i <= to end)
      |> Enum.reduce_while(%{}, fn
        {{:open, name, _, _}, _}, depths when name in @strict ->
          {:cont, Map.update(depths, name, 1, &(&1 + 1))}

        {{:close, name, _}, _}, depths when name in @strict ->
          case Map.get(depths, name, 0) do
            0 -> {:halt, :unbalanced}
            n -> {:cont, Map.put(depths, name, n - 1)}
          end

        _, depths ->
          {:cont, depths}
      end)

    result != :unbalanced and Enum.all?(result, fn {_, n} -> n == 0 end)
  end

  defp pieces(inner, {h_open, h_close}, {f_open, f_close}) do
    slice = fn from, to -> Enum.filter(inner, fn {_, i} -> i >= from and i <= to end) end

    %{
      header: slice.(h_open, h_close),
      middle: slice.(h_close + 1, f_open - 1),
      footer: slice.(f_open, f_close)
    }
  end

  # ── assembly ──────────────────────────────────────────────────────────

  defp assemble(%{header: header, middle: middle, footer: footer}, tokens, rules, accent?) do
    {header_part, header_note} = header_part(header, tokens, rules, accent?)
    {footer_part, footer_note} = footer_part(footer, tokens, rules, accent?)
    middle_part = middle |> unwrap_content() |> render(tokens, rules, accent?)

    fragment =
      [header_part, middle_part, footer_part]
      |> Enum.map(&tidy/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> Kernel.<>("\n")

    notes =
      case Enum.reject([header_note, footer_note], &is_nil/1) do
        [] -> []
        dropped -> [{:chrome_dropped, dropped}]
      end

    {fragment, notes}
  end

  # The header's contents are the email's title when it holds a heading.
  defp header_part(header, tokens, rules, accent?) do
    [{open_token, _} | rest] = header
    interior = rest |> Enum.drop(-1)

    if Enum.any?(interior, fn {t, _} -> heading?(t) end) do
      {render_wrapped(open_token, header, interior, tokens, rules, accent?), nil}
    else
      {"", dropped_text("header", interior)}
    end
  end

  defp heading?({:open, name, _, _}), do: name in @headings
  defp heading?(_), do: false

  defp footer_part(footer, tokens, rules, accent?) do
    interior = footer |> Enum.drop(1) |> Enum.drop(-1)

    if Enum.any?(interior, fn {t, _} -> placeholder?(t) end) do
      {render(footer, tokens, rules, accent?), nil}
    else
      {"", dropped_text("footer", interior)}
    end
  end

  defp placeholder?({:text, text}), do: String.contains?(text, "{{")
  defp placeholder?({:open, _, attrs, _}), do: String.contains?(attrs, "{{")
  defp placeholder?({:void, _, attrs, _}), do: String.contains?(attrs, "{{")
  defp placeholder?(_), do: false

  defp dropped_text(label, interior) do
    text =
      interior
      |> Enum.flat_map(fn
        {{:text, t}, _} -> [t]
        _ -> []
      end)
      |> Enum.join(" ")
      |> String.split()
      |> Enum.join(" ")

    if text == "", do: nil, else: "#{label}: #{text}"
  end

  # Header kept for its heading: its own box reduced to alignment and margins.
  defp render_wrapped(
         {:open, _name, _attrs, _raw} = open,
         header,
         interior,
         tokens,
         rules,
         accent?
       ) do
    {_, header_index} = hd(header)
    decls = declarations_for(open, header_index, tokens, rules, accent?)
    props = Enum.filter(decls, fn {prop, _} -> prop in @header_props end)
    body = interior |> render(tokens, rules, accent?) |> tidy()

    case props do
      [] -> body
      _ -> ~s(<div style="#{format_decls(props)}">\n#{indent(body)}\n</div>)
    end
  end

  defp indent(text), do: "  " <> String.replace(text, "\n", "\n  ")

  # A lone `.content` wrapper around the region is unwrapped.
  defp unwrap_content(middle) do
    significant = Enum.reject(middle, fn {t, _} -> blank?(t) end)

    case significant do
      [{{:open, name, attrs, _}, first} | _] = all ->
        {_, last} = List.last(all)

        if "content" in classes(attrs) and matching_close(all, first, name) == last do
          Enum.filter(middle, fn {_, i} -> i > first and i < last end)
        else
          middle
        end

      _ ->
        middle
    end
  end

  defp blank?({:text, t}), do: String.trim(t) == ""
  defp blank?({:comment, _}), do: true
  defp blank?(_), do: false

  # ── rendering with inlined styles ─────────────────────────────────────

  defp render(indexed, tokens, rules, accent?) do
    Enum.map_join(indexed, fn
      {{:open, _, _, raw} = token, i} -> restyle(token, raw, i, tokens, rules, accent?)
      {{:void, _, _, raw} = token, i} -> restyle(token, raw, i, tokens, rules, accent?)
      {{:text, t}, _} -> t
      {{:comment, t}, _} -> t
      {{:decl, t}, _} -> t
      {{:close, _, raw}, _} -> raw
    end)
  end

  defp restyle({_kind, name, attrs, raw}, raw, index, tokens, rules, accent?) do
    decls = declarations_for({:open, name, attrs, raw}, index, tokens, rules, accent?)

    case decls do
      [] -> raw
      _ -> rebuild(binary_part(raw, 1, byte_size(name)), attrs, decls)
    end
  end

  defp rebuild(name, attrs, css) do
    inline = inline_style(attrs)
    inline_props = Enum.map(inline, &elem(&1, 0))
    own = Enum.reject(css, fn {prop, _} -> prop in inline_props end)
    style = format_decls(own ++ inline)

    {without_style, tail} = split_tail(strip_style(attrs))
    "<#{name}#{without_style} style=\"#{style}\"#{tail}>"
  end

  defp split_tail(attrs) do
    trimmed = String.trim_trailing(attrs)

    if String.ends_with?(trimmed, "/") do
      {trimmed |> String.trim_trailing("/") |> String.trim_trailing(), " /"}
    else
      {trimmed, ""}
    end
  end

  defp format_decls(decls) do
    Enum.map_join(decls, "; ", fn {prop, val} -> "#{prop}: #{String.replace(val, "\"", "'")}" end) <>
      ";"
  end

  defp strip_style(attrs), do: Regex.replace(~r/\sstyle\s*=\s*("[^"]*"|'[^']*')/i, attrs, "")

  defp inline_style(attrs) do
    case Regex.run(~r/\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)')/i, attrs) do
      nil -> []
      [_, value] -> parse_declarations(value)
      [_, "", value] -> parse_declarations(value)
      [_, value | _] -> parse_declarations(value)
    end
  end

  defp classes(attrs) do
    case Regex.run(~r/\sclass\s*=\s*(?:"([^"]*)"|'([^']*)')/i, attrs) do
      nil -> []
      [_, value] -> String.split(value)
      [_, "", value] -> String.split(value)
      [_, value | _] -> String.split(value)
    end
  end

  # ── CSS ───────────────────────────────────────────────────────────────

  defp style_rules(tokens) do
    tokens
    |> Enum.chunk_while(
      nil,
      fn
        {:open, "style", _, _}, _ -> {:cont, :style}
        {:text, css}, :style -> {:cont, css, nil}
        _, state -> {:cont, state}
      end,
      fn _ -> {:cont, nil} end
    )
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&parse_css/1)
    |> Enum.with_index()
    |> Enum.map(fn {rule, order} -> Map.put(rule, :order, order) end)
  end

  defp parse_css(css) do
    css |> String.replace(~r{/\*.*?\*/}s, "") |> parse_rules([])
  end

  defp parse_rules(css, acc) do
    case :binary.match(css, "{") do
      :nomatch ->
        Enum.reverse(acc)

      {at, 1} ->
        selector = css |> binary_part(0, at) |> String.trim()
        rest = binary_part(css, at + 1, byte_size(css) - at - 1)

        if String.starts_with?(selector, "@") do
          parse_rules(skip_block(rest, 1), acc)
        else
          case :binary.match(rest, "}") do
            :nomatch ->
              Enum.reverse(acc)

            {close, 1} ->
              body = binary_part(rest, 0, close)
              tail = binary_part(rest, close + 1, byte_size(rest) - close - 1)
              parse_rules(tail, rules_for(selector, parse_declarations(body)) ++ acc)
          end
        end
    end
  end

  # Past the `}` that closes an at-rule block whose `{` was already consumed.
  defp skip_block(css, 0), do: css
  defp skip_block(<<>>, _depth), do: <<>>
  defp skip_block(<<"{", rest::binary>>, depth), do: skip_block(rest, depth + 1)
  defp skip_block(<<"}", rest::binary>>, depth), do: skip_block(rest, depth - 1)
  defp skip_block(<<_, rest::binary>>, depth), do: skip_block(rest, depth)

  defp rules_for(selector, decls) do
    selector
    |> String.split(",")
    |> Enum.flat_map(fn sel ->
      case parse_selector(String.trim(sel)) do
        nil -> []
        compounds -> [%{compounds: compounds, decls: decls, specificity: specificity(compounds)}]
      end
    end)
    |> Enum.reverse()
  end

  # [{tag | nil, [class]}] in source order, or nil for anything unsupported.
  defp parse_selector(""), do: nil

  defp parse_selector(selector) do
    parts = String.split(selector)
    parsed = Enum.map(parts, &parse_compound/1)
    if Enum.any?(parsed, &is_nil/1), do: nil, else: parsed
  end

  defp parse_compound(part) do
    if Regex.match?(~r/\A[a-zA-Z0-9]*(?:\.[a-zA-Z_][a-zA-Z0-9_-]*)*\z/, part) and part != "" do
      [tag | classes] = String.split(part, ".")
      {if(tag == "", do: nil, else: String.downcase(tag)), classes}
    end
  end

  defp specificity(compounds) do
    Enum.reduce(compounds, 0, fn {tag, classes}, acc ->
      acc + length(classes) * 10 + if(tag, do: 1, else: 0)
    end)
  end

  defp parse_declarations(body) do
    body
    |> String.split(";")
    |> Enum.flat_map(fn decl ->
      case String.split(decl, ":", parts: 2) do
        [prop, val] ->
          prop = prop |> String.trim() |> String.downcase()
          val = String.trim(val)
          if prop == "" or val == "", do: [], else: [{prop, val}]

        _ ->
          []
      end
    end)
  end

  # The merged declarations of every rule matching the element at `index`,
  # lowest specificity first so the strongest wins.
  defp declarations_for({:open, name, attrs, _raw}, index, tokens, rules, accent?) do
    element = {name, classes(attrs)}
    ancestors = ancestors(tokens, index)

    rules
    |> Enum.filter(&matches?(&1.compounds, element, ancestors))
    |> Enum.sort_by(&{&1.specificity, &1.order})
    |> Enum.flat_map(& &1.decls)
    |> Enum.reduce([], fn {prop, val}, acc -> List.keystore(acc, prop, 0, {prop, val}) end)
    |> accent(element, accent?)
  end

  defp accent(decls, {_name, classes}, true) do
    if "button" in classes do
      Enum.map(decls, fn
        {"background-color", val} = decl ->
          if String.downcase(val) in @default_blues,
            do: {"background-color", "{{accent_color}}"},
            else: decl

        decl ->
          decl
      end)
    else
      decls
    end
  end

  defp accent(decls, _element, _accent?), do: decls

  # Open ancestors of the token at `index`, nearest first, as {name, classes}.
  defp ancestors(tokens, index) do
    tokens
    |> Enum.take(index)
    |> Enum.reduce([], fn
      {{:open, name, attrs, _}, _}, stack -> [{name, classes(attrs)} | stack]
      {{:close, name, _}, _}, stack -> pop(stack, name)
      _, stack -> stack
    end)
  end

  defp pop(stack, name) do
    case Enum.split_while(stack, fn {n, _} -> n != name end) do
      {_skipped, [_ | rest]} -> rest
      {_all, []} -> stack
    end
  end

  defp matches?(compounds, element, ancestors) do
    [last | rest] = Enum.reverse(compounds)
    compound_matches?(last, element) and ancestors_match?(rest, ancestors)
  end

  defp ancestors_match?([], _ancestors), do: true
  defp ancestors_match?(_compounds, []), do: false

  defp ancestors_match?([compound | more] = compounds, [ancestor | up]) do
    if compound_matches?(compound, ancestor),
      do: ancestors_match?(more, up),
      else: ancestors_match?(compounds, up)
  end

  defp compound_matches?({tag, classes}, {name, element_classes}) do
    (tag == nil or tag == name) and Enum.all?(classes, &(&1 in element_classes))
  end

  # ── output tidy-up ────────────────────────────────────────────────────

  # Trim blank edges and remove the indentation the seed's nesting added. A
  # piece starts at a tag, so its first line carries none of that indentation:
  # it is the lines after it that say how deep the piece sat.
  defp tidy(text) do
    [first | rest] = text |> String.split("\n") |> Enum.map(&String.trim_trailing/1)

    indent =
      rest
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&(byte_size(&1) - byte_size(String.trim_leading(&1))))
      |> Enum.min(fn -> 0 end)

    rest = Enum.map(rest, &drop_indent(&1, indent))

    [String.trim_leading(first) | rest]
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp drop_indent("", _indent), do: ""
  defp drop_indent(line, indent), do: binary_part(line, indent, byte_size(line) - indent)
end
