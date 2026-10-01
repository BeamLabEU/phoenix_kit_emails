defmodule PhoenixKit.Modules.Emails.TemplateExport.BodyTest do
  @moduledoc """
  Cutting a stored full-document `html_body` down to the body fragment an
  `html.html` override holds — on documents shaped like the seeds, and on the
  shapes hosts turn them into.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.TemplateExport.Body

  @css """
  body { font-family: sans-serif; color: #333; }
  .header { text-align: center; margin-bottom: 30px; background: linear-gradient(#000, #111); color: white; }
  .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; }
  .button:hover { background-color: #2563eb; }
  .footer { margin-top: 30px; border-top: 1px solid #e5e7eb; font-size: 14px; }
  .warning { background-color: #fef3c7; padding: 16px; }
  .content { padding: 30px; }
  """

  # The shape of the four auth seeds: the body sits directly between the
  # header and the footer, in no wrapper of its own.
  defp auth_doc(opts \\ []) do
    title = Keyword.get(opts, :title, "Welcome! Please confirm your account")
    greeting = Keyword.get(opts, :greeting, "Hi {{user_email}},")
    css = Keyword.get(opts, :css, @css)
    header = Keyword.get(opts, :header, ~s(<h1>#{title}</h1>))

    footer =
      Keyword.get(
        opts,
        :footer,
        ~s(<p>Or paste this link:</p>\n      <p><a href="{{confirmation_url}}">{{confirmation_url}}</a></p>)
      )

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Confirm</title>
      <style>
    #{css}
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          #{header}
        </div>

        <p>#{greeting}</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{confirmation_url}}" class="button">Confirm My Account</a>
        </p>

        <div class="warning">
          <strong>Note:</strong> secure link.
        </div>

        <div class="footer">
          #{footer}
        </div>
      </div>
    </body>
    </html>
    """
  end

  # The shape of five seeds: the body is wrapped in `.content`.
  defp content_doc do
    """
    <!DOCTYPE html>
    <html>
    <head><style>#{@css}</style></head>
    <body>
      <div class="container">
        <div class="header"><h1>Invoice</h1></div>
        <div class="content">
          <p>Dear {{user_name}}</p>
          <table><tr><td>{{{line_items_html}}}</td></tr></table>
        </div>
        <div class="footer"><p>{{company_name}}</p></div>
      </div>
    </body>
    </html>
    """
  end

  defp placeholders(html) do
    ~r/\{\{\{?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}?\}\}/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  describe "document?/1" do
    test "recognises a doctype or an <html> tag, in any case, after a prolog" do
      assert Body.document?("<!DOCTYPE html><html></html>")
      assert Body.document?("<!doctype html>")
      assert Body.document?("<HTML lang=\"en\"><body></body></HTML>")
      assert Body.document?("﻿  \n<!-- c --><?xml version=\"1.0\"?>\n<html>")
    end

    test "a fragment is not a document" do
      refute Body.document?("<p>Hi</p>")
      refute Body.document?("<htmlish>")
      refute Body.document?("")
      refute Body.document?("Hello <html> later")
    end
  end

  describe "extract/2 — fragments and documents" do
    test "a fragment comes back unchanged, without notes" do
      assert Body.extract("<p>Hi {{name}}</p>\n") == {"<p>Hi {{name}}</p>\n", []}
    end

    test "cuts the document down to the body: no head, style, body or container" do
      {fragment, notes} = Body.extract(auth_doc())

      assert notes == []

      for gone <- [
            "<html",
            "<head",
            "<style",
            "<body",
            "<!DOCTYPE",
            "<title",
            ~s(class="container")
          ] do
        refute fragment =~ gone, "#{gone} should be gone"
      end

      assert fragment =~ "<p>Hi {{user_email}},</p>"
      assert fragment =~ ~s(href="{{confirmation_url}}")
    end

    test "the body is whatever sits between the header and the footer, with or without .content" do
      {auth, _} = Body.extract(auth_doc())
      {with_content, _} = Body.extract(content_doc())

      assert auth =~ "Confirm My Account"
      assert with_content =~ "Dear {{user_name}}"
      # `.content` is unwrapped — the layout owns padding — so its rule is not applied.
      refute with_content =~ ~s(class="content")
      refute with_content =~ "padding: 30px"
    end

    test "a .content that does not wrap the whole region is left alone" do
      doc =
        String.replace(
          content_doc(),
          ~s(<table>),
          ~s(</div><p>after</p><div class="content"><table>)
        )

      {fragment, _} = Body.extract(doc)
      assert fragment =~ "after"
    end

    test "every placeholder of the original body survives" do
      for doc <- [auth_doc(), content_doc()] do
        {fragment, _} = Body.extract(doc)
        [_, body] = Regex.run(~r/<body>(.*)<\/body>/s, doc)
        assert MapSet.subset?(placeholders(body), placeholders(fragment))
      end
    end

    test "raw {{{triple}}} placeholders pass through untouched" do
      {fragment, _} = Body.extract(content_doc())
      assert fragment =~ "{{{line_items_html}}}"
    end

    test "a host's edits in several locales come through, each file on its own" do
      de =
        auth_doc(
          title: "Willkommen! Bitte bestätigen",
          greeting: "Hallo {{user_email}}, schön dass Sie da sind"
        )

      ru = auth_doc(title: "Добро пожаловать", greeting: "Здравствуйте, {{user_email}} 👋")

      {de_fragment, []} = Body.extract(de)
      {ru_fragment, []} = Body.extract(ru)

      assert de_fragment =~ "Willkommen! Bitte bestätigen"
      assert de_fragment =~ "Hallo {{user_email}}, schön dass Sie da sind"
      assert ru_fragment =~ "Добро пожаловать"
      assert ru_fragment =~ "Здравствуйте, {{user_email}} 👋"
      refute de_fragment =~ "Здравствуйте"
    end

    test "the result is a fragment: extracting it again changes nothing" do
      {once, _} = Body.extract(auth_doc())
      assert Body.extract(once) == {once, []}
    end

    test "indentation of the seed's nesting is removed and edges are trimmed" do
      {fragment, _} = Body.extract(auth_doc())

      assert String.starts_with?(fragment, "<div")
      assert String.ends_with?(fragment, "</div>\n")
      refute fragment =~ "\n\n\n"
      refute fragment =~ ~r/^ {6,}</m
    end
  end

  describe "extract/2 — header and footer" do
    test "a header with a heading keeps the title, without its own background or colour" do
      {fragment, []} = Body.extract(auth_doc())

      assert fragment =~ "<h1>Welcome! Please confirm your account</h1>"
      assert fragment =~ "text-align: center"
      refute fragment =~ "linear-gradient"
      [header_block | _] = String.split(fragment, "</div>")
      refute header_block =~ "white"
      refute fragment =~ ~s(class="header")
    end

    test "a header with no heading is chrome: dropped, and its text is reported" do
      {fragment, notes} =
        Body.extract(auth_doc(header: ~s(<img src="x.png" alt="Acme Ltd">Acme Ltd)))

      refute fragment =~ "Acme Ltd"
      assert {:chrome_dropped, ["header: Acme Ltd"]} in notes
    end

    test "a header with nothing to say is dropped without a note" do
      {_, notes} = Body.extract(auth_doc(header: ~s(<img src="x.png" alt="logo">)))
      assert notes == []
    end

    test "a footer holding a placeholder is kept as the last block of the body" do
      {fragment, []} = Body.extract(auth_doc())

      assert fragment =~ "Or paste this link:"
      assert fragment =~ "margin-top: 30px"
      assert String.ends_with?(String.trim_trailing(fragment), "</div>")
      {footer_at, _} = :binary.match(fragment, "Or paste this link")
      {button_at, _} = :binary.match(fragment, "Confirm My Account")
      assert footer_at > button_at
    end

    test "a footer with no placeholder is chrome: dropped, and its text is reported" do
      {fragment, notes} = Body.extract(auth_doc(footer: "<p>© 2026   Acme Ltd, Tallinn</p>"))

      refute fragment =~ "Acme Ltd"
      assert {:chrome_dropped, ["footer: © 2026 Acme Ltd, Tallinn"]} in notes
    end

    test "dropped header and footer are reported together in one note" do
      {_, notes} =
        Body.extract(auth_doc(header: "Acme", footer: "<p>Tallinn</p>"))

      assert [{:chrome_dropped, ["header: Acme", "footer: Tallinn"]}] = notes
    end
  end

  describe "extract/2 — falling back" do
    test "without a .header or .footer the whole body is kept, with a note" do
      doc = """
      <html><head><style>p { color: red; }</style></head>
      <body><div class="wrapper"><p>Hello {{name}}</p></div></body></html>
      """

      {fragment, notes} = Body.extract(doc)

      assert fragment =~ "Hello {{name}}"
      assert fragment =~ "wrapper"
      refute fragment =~ "<body"
      assert [{:body_fallback, [reason]}] = notes
      assert reason =~ ".header"
    end

    test "a header without a footer is a fallback too, never a guess" do
      doc = """
      <html><body><div><div class="header"><h1>T</h1></div><p>Body</p></div></body></html>
      """

      {fragment, [{:body_fallback, [reason]}]} = Body.extract(doc)
      assert reason =~ ".footer"
      assert fragment =~ "Body"
    end

    test "a header and footer that are not siblings are a fallback" do
      doc = """
      <html><body>
        <div class="a"><div class="header"><h1>T</h1></div><p>one</p></div>
        <p>two</p>
        <div class="footer"><p>{{x}}</p></div>
      </body></html>
      """

      {fragment, [{:body_fallback, [reason]}]} = Body.extract(doc)
      assert reason =~ "siblings"
      assert fragment =~ "one" and fragment =~ "two"
    end

    test "a document without <body> still yields what follows the head" do
      doc = ~s(<html><head><title>x</title></head><p class="x">Hi</p></html>)
      {fragment, [{:body_fallback, _}]} = Body.extract(doc)
      assert fragment =~ "Hi"
      refute fragment =~ "<title"
    end
  end

  describe "extract/2 — inlined styles" do
    test "a class rule becomes the element's style attribute" do
      {fragment, _} = Body.extract(auth_doc())

      assert fragment =~
               ~s(<div class="warning" style="background-color: #fef3c7; padding: 16px;">)
    end

    test "the button keeps its look" do
      {fragment, _} = Body.extract(auth_doc())

      assert fragment =~
               ~s(href="{{confirmation_url}}" class="button" style="display: inline-block;)

      assert fragment =~ "background-color: #3b82f6"
      assert fragment =~ "color: white"
    end

    test "an existing inline style wins over the rule" do
      css = ".p { margin: 1px; color: red; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <p class="p" style="color: blue">x</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<p class="p" style="margin: 1px; color: blue;">)
    end

    test "a higher specificity beats a later rule" do
      css = ".box .item { color: red; } .item { color: blue; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <div class="box"><span class="item">x</span></div>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<span class="item" style="color: red;">)
    end

    test "descendant selectors match through the ancestors the cut removed" do
      css = ".header h1 { font-size: 28px; } .content p { color: green; } td { padding: 5px; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="container"><div class="header"><h1>T</h1></div>
      <div class="content"><p>x</p><table><tr><td>y</td></tr></table></div>
      <div class="footer">{{u}}</div></div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<h1 style="font-size: 28px;">)
      assert fragment =~ ~s(<p style="color: green;">)
      assert fragment =~ ~s(<td style="padding: 5px;">)
    end

    test "selectors that cannot be inlined are skipped, not misapplied" do
      css = """
      a:hover { color: red; }
      .a > .b { color: red; }
      #id { color: red; }
      * { color: red; }
      @media (max-width: 600px) { .a { color: red; } }
      .a { margin: 0; }
      /* .a { color: purple; } */
      """

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <div class="a"><span class="b" id="id">x</span></div>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<div class="a" style="margin: 0;">)
      assert fragment =~ ~s(<span class="b" id="id">)
      refute fragment =~ "red"
      refute fragment =~ "purple"
    end

    test "a selector list applies to each member" do
      css = ".x, .y { margin: 2px; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <i class="x">1</i><i class="y">2</i><i class="z">3</i>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<i class="x" style="margin: 2px;">)
      assert fragment =~ ~s(<i class="y" style="margin: 2px;">)
      assert fragment =~ ~s(<i class="z">)
    end

    test "a self-closing element keeps its slash" do
      css = ".r { border: 0; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <hr class="r" /><br class="r">
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<hr class="r" style="border: 0;" />)
      assert fragment =~ ~s(<br class="r" style="border: 0;">)
    end
  end

  describe "extract/2 — accent colour" do
    test "off by default: the button's literal colour stays" do
      {fragment, _} = Body.extract(auth_doc())
      assert fragment =~ "background-color: #3b82f6"
      refute fragment =~ "accent_color"
    end

    test "with accent: true the default blue of a button becomes {{accent_color}}" do
      {fragment, _} = Body.extract(auth_doc(), accent: true)
      assert fragment =~ "background-color: {{accent_color}}"
      refute fragment =~ "#3b82f6"
    end

    test "a button colour that carries meaning is kept, and so is a non-button blue" do
      css = """
      .button { background-color: #dc2626; color: white; }
      .warning { background-color: #3b82f6; }
      """

      {fragment, _} = Body.extract(auth_doc(css: css), accent: true)
      assert fragment =~ "background-color: #dc2626"
      assert fragment =~ ~s(<div class="warning" style="background-color: #3b82f6;">)
    end
  end

  describe "extract/2 — tokenizer" do
    test "a > inside a quoted attribute does not end the tag" do
      doc = """
      <html><body>
      <div class="header"><h1>T</h1></div>
      <p title="a > b" data-x='1 > 0'>text {{x}}</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ ~s(<p title="a > b" data-x='1 > 0'>text {{x}}</p>)
    end

    test "comments, entities and a stray < in text are kept verbatim" do
      doc = """
      <html><body>
      <div class="header"><h1>T</h1></div>
      <!-- keep me --><p>1 < 2 &amp; 3 &gt; 2 &nbsp;</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ "<!-- keep me -->"
      assert fragment =~ "1 < 2 &amp; 3 &gt; 2 &nbsp;"
    end

    test "an unclosed <p> or <li> does not upset the cut" do
      doc = """
      <html><body><div class="header"><h1>T</h1></div>
      <ul><li>one<li>two</ul><p>loose
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ "<li>one<li>two</ul>"
      assert fragment =~ "loose"
    end

    test "a style block with a < in a comment, and uppercase tags, are handled" do
      doc = """
      <HTML><HEAD><STYLE>/* a < b */ .p { margin: 3px; }</STYLE></HEAD><BODY>
      <DIV CLASS="header"><H1>T</H1></DIV>
      <P class="p">x</P>
      <DIV class="footer">{{u}}</DIV></BODY></HTML>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<P class="p" style="margin: 3px;">x</P>)
    end

    test "an unterminated tag or comment does not hang or crash" do
      assert {_, _} = Body.extract("<html><body><div class=\"header\"><h1>T</h1></div><p <!-- ")
      assert {_, _} = Body.extract("<html><body><div class=\"header")
    end
  end
end
