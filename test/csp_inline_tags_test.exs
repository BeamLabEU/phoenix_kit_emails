defmodule PhoenixKitEmails.CSPInlineTagsTest do
  @moduledoc """
  The admin pages of this module work under a host Content-Security-Policy that allows
  inline code by nonce only (`script-src 'self' 'nonce-…'`): no inline event handler (no
  nonce can cover an attribute) and no inline `<script>` / `<style>` without a nonce.

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # E-mail bodies, not pages: a mail client does not apply the host's policy, and a nonce of
  # one request must never be written into a message.
  @email_bodies [
    "lib/phoenix_kit/modules/emails/templates.ex"
  ]

  # Files that handle `<style>` / `<script>` as text (the export cuts them out of a legacy
  # template body and reports on them), not as markup they render.
  @tags_as_data [
    "lib/phoenix_kit/modules/emails/template_export.ex",
    "lib/phoenix_kit/modules/emails/template_export/body.ex"
  ]

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @email_bodies,
          path not in @tags_as_data,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not String.contains?(opening, "nonce"),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (feature-detect `PhoenixKitWeb.CSP.nonce/1`, " <>
             "see AGENTS.md):\n" <> Enum.join(offenders, "\n")
  end

  test "the exempt files exist and are still the ones with the tags" do
    for path <- @email_bodies ++ @tags_as_data do
      assert File.exists?(path), "#{path} is gone: remove it from the exemptions"
    end

    assert tag_openings(hd(@email_bodies)) != []
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  # The e-mail bodies are scanned too: a handler in a message is dead in every mail client.
  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, or core's " <>
             "`data-pk-blur` for a dropdown that closes after a choice):\n" <>
             Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<ul data-pk-blur phx-click="go">) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  # The module ships no JavaScript. One that appears is checked by hand until this test
  # learns to scan it (see core's test for the bundle checks).
  test "the module ships no JavaScript of its own" do
    assert Path.wildcard("{lib,priv}/**/*.{js,ts}") == []
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
