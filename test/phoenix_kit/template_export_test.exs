defmodule PhoenixKit.Modules.Emails.TemplateExportTest do
  @moduledoc """
  Which stored templates become override files, and what those files are
  called — the two questions the move off the templates table turns on.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates

  defp template(attrs) do
    struct(
      %Template{
        name: "register",
        is_system: true,
        subject: %{"en" => "Confirm your account"},
        text_body: %{"en" => "Hi there"},
        html_body: %{}
      },
      attrs
    )
  end

  defp shipped,
    do: [
      %{
        name: "register",
        subject: %{"en" => "Confirm your account"},
        text_body: %{"en" => "Hi there"},
        html_body: %{}
      }
    ]

  describe "edited?/2" do
    test "an untouched row is not edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})
      refute TemplateExport.edited?(template(%{}), by_name)
    end

    test "a row whose content differs is edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})

      assert TemplateExport.edited?(template(%{subject: %{"en" => "Please confirm"}}), by_name)
      assert TemplateExport.edited?(template(%{text_body: %{"en" => "Custom"}}), by_name)
      assert TemplateExport.edited?(template(%{html_body: %{"en" => "<p>x</p>"}}), by_name)
    end

    test "a row gaining a translation is edited" do
      # Adding a locale is a customization worth carrying out, even though the
      # English content the package shipped is untouched.
      by_name = Map.new(shipped(), &{&1.name, &1})
      extra = template(%{subject: %{"en" => "Confirm your account", "uk" => "Підтвердіть"}})

      assert TemplateExport.edited?(extra, by_name)
    end

    test "a name this package does not ship counts as edited" do
      # Nothing is known about what it should look like, and a file too many is
      # recoverable where a dropped edit is not.
      assert TemplateExport.edited?(template(%{name: "something_bespoke"}), %{})
    end

    test "metadata differences do not make a template edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})
      busy = template(%{usage_count: 900, slug: "renamed", status: "draft"})

      refute TemplateExport.edited?(busy, by_name)
    end
  end

  describe "files_for/2 — the locale rule" do
    test "the fallback locale is written WITHOUT a locale in the filename" do
      # This is the load-bearing one. The stored map's fallback is what every
      # recipient without their own translation receives; core falls through to
      # the locale-LESS file. Writing it as subject.en.txt would silently drop
      # the operator's customization for every non-English recipient.
      files = TemplateExport.files_for(template(%{}), "out")

      assert {"out/register/subject.txt", "Confirm your account"} in files
      refute Enum.any?(files, fn {path, _} -> path =~ "subject.en.txt" end)
    end

    test "every other locale carries its code" do
      t = template(%{subject: %{"en" => "Confirm", "uk" => "Підтвердіть", "de" => "Bestätigen"}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/subject.txt" in paths
      assert "out/register/subject.uk.txt" in paths
      assert "out/register/subject.de.txt" in paths
    end

    test "without an English key the lowest-sorting locale is the fallback" do
      t = template(%{subject: %{"uk" => "Підтвердіть", "de" => "Bestätigen"}, text_body: %{}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/subject.txt" in paths
      assert "out/register/subject.uk.txt" in paths
      refute "out/register/subject.de.txt" in paths
    end

    test "html goes to .html, subject and text to .txt" do
      t = template(%{html_body: %{"en" => "<p>hi</p>"}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/html.html" in paths
      assert "out/register/subject.txt" in paths
      assert "out/register/text.txt" in paths
    end

    test "a part with no content produces no file" do
      t = template(%{html_body: %{"en" => ""}, text_body: %{"en" => nil}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert paths == ["out/register/subject.txt"]
    end
  end

  describe "plan/3" do
    test "separates edited, untouched and operator-authored rows" do
      edited = template(%{name: "register", subject: %{"en" => "Please confirm"}})
      untouched = template(%{})
      authored = template(%{name: "newsletter_wrapper", is_system: false})

      plan = TemplateExport.plan([edited, untouched, authored], shipped(), out: "out")

      assert [%Template{subject: %{"en" => "Please confirm"}}] = plan.edited
      assert [%Template{subject: %{"en" => "Confirm your account"}}] = plan.untouched
      assert [%Template{name: "newsletter_wrapper"}] = plan.authored
    end

    test "only edited rows produce files" do
      plan =
        TemplateExport.plan([template(%{}), template(%{name: "x", is_system: false})], shipped())

      assert plan.files == []
    end
  end

  describe "plan/3 — raw HTML variables" do
    defp invoice(html) do
      template(%{
        name: "billing_invoice",
        subject: %{"en" => "Invoice"},
        text_body: %{"en" => "{{line_items_html}} as text, never rewritten"},
        html_body: %{"en" => html}
      })
    end

    defp invoice_shipped do
      [
        %{
          name: "billing_invoice",
          subject: %{"en" => "shipped subject"},
          text_body: %{"en" => "shipped text"},
          html_body: %{"en" => "shipped html"}
        }
      ]
    end

    defp html_file(plan) do
      Enum.find_value(plan.files, fn {path, content} ->
        if String.ends_with?(path, "html.html"), do: content
      end)
    end

    test "rewrites a known raw-html variable to triple braces when supported" do
      html = "<p>{{user_name}}</p>{{line_items_html}}<p>{{total}}</p>"

      plan =
        TemplateExport.plan([invoice(html)], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "<p>{{user_name}}</p>{{{line_items_html}}}<p>{{total}}</p>"

      assert Enum.any?(
               plan.notices,
               &(&1 =~ "rewrote {{line_items_html}} to {{{line_items_html}}}")
             )
    end

    test "never rewrites subject or text, even when they contain the same name" do
      plan =
        TemplateExport.plan([invoice("plain html")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      contents = Map.new(plan.files)

      assert contents["out/billing_invoice/text.txt"] ==
               "{{line_items_html}} as text, never rewritten"

      refute Enum.any?(plan.notices, &(&1 =~ "text.txt"))
    end

    test "is idempotent — an already-triple-brace placeholder is left alone" do
      plan =
        TemplateExport.plan([invoice("{{{line_items_html}}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "{{{line_items_html}}}"
      assert plan.notices == []
    end

    test "leaves double braces and warns when the loaded templates version is too old" do
      plan =
        TemplateExport.plan([invoice("{{line_items_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: false
        )

      assert html_file(plan) == "{{line_items_html}}"

      assert Enum.any?(
               plan.notices,
               &(&1 =~ "does not support {{{...}}}" and
                   &1 =~ "replace {{line_items_html}} with {{{line_items_html}}}")
             )
    end

    test "warns about an unrecognized _html placeholder and leaves it untouched" do
      plan =
        TemplateExport.plan([invoice("{{mystery_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "{{mystery_html}}"
      assert Enum.any?(plan.notices, &(&1 =~ "unknown raw-HTML placeholder {{mystery_html}}"))
    end

    test "uses the loaded phoenix_kit_templates version when the option is omitted" do
      # This repo's mix.lock pins phoenix_kit_templates to 0.1.2, which has no
      # triple-brace support — see CLAUDE/AGENTS notes on why that lock stays put.
      plan = TemplateExport.plan([invoice("{{line_items_html}}")], invoice_shipped(), out: "out")

      assert html_file(plan) == "{{line_items_html}}"
      assert Enum.any?(plan.notices, &(&1 =~ "does not support {{{...}}}"))
    end
  end

  describe "rewrite_raw_html/3" do
    test "rewrites every occurrence of a known variable" do
      {content, notices} =
        TemplateExport.rewrite_raw_html(
          "{{line_items_html}}...{{ line_items_html }}",
          "some/path/html.html",
          true
        )

      assert content == "{{{line_items_html}}}...{{{line_items_html}}}"
      assert length(notices) == 1
      assert hd(notices) =~ "some/path/html.html"
    end

    test "an unbound unrelated placeholder is left alone" do
      {content, notices} = TemplateExport.rewrite_raw_html("{{total}}", "x.html", true)

      assert content == "{{total}}"
      assert notices == []
    end

    # Boundary cases from PhoenixKit.Templates.Substitution's own moduledoc —
    # the "obvious" reading of these is wrong, and this module copies that
    # package's placeholder syntax without depending on it, so these pin the
    # copy down independently of that source ever changing underneath it.
    test "an already-quadruple-brace placeholder is recognized as a triple inside literal braces" do
      # {{{{x}}}} parses as literal `{` + the triple-brace placeholder + literal
      # `}` — already raw, so nothing to rewrite.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{{{line_items_html}}}}", "x.html", true)

      assert content == "{{{{line_items_html}}}}"
      assert notices == []
    end

    test "a triple-brace placeholder missing its third closing brace still rewrites the double form underneath" do
      # Only two closing braces exist, so the triple form has nothing to
      # complete; the double form does, one character in, leaving the first
      # `{` as a literal that survives the rewrite untouched.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{{line_items_html}}", "x.html", true)

      assert content == "{{{{line_items_html}}}"

      assert notices == [
               "x.html: rewrote {{line_items_html}} to {{{line_items_html}}} (already-rendered HTML)"
             ]
    end

    test "a double-brace placeholder with one extra trailing brace rewrites underneath it" do
      # Mirror of the row above: the double form completes as {{x}}; the
      # extra trailing `}` is literal and survives the rewrite untouched.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{line_items_html}}}", "x.html", true)

      assert content == "{{{line_items_html}}}}"

      assert notices == [
               "x.html: rewrote {{line_items_html}} to {{{line_items_html}}} (already-rendered HTML)"
             ]
    end

    test "single outer braces are never part of the placeholder" do
      {content, notices} =
        TemplateExport.rewrite_raw_html("{ {{line_items_html}} }", "x.html", true)

      assert content == "{ {{{line_items_html}}} }"

      assert notices == [
               "x.html: rewrote {{line_items_html}} to {{{line_items_html}}} (already-rendered HTML)"
             ]
    end
  end

  describe "against the templates this package actually ships" do
    test "a freshly seeded row would export nothing" do
      # The whole point of the classification: an install that never touched a
      # template exports zero files, so the diff an operator reviews contains
      # only their own edits.
      shipped = Templates.default_system_templates()

      rows =
        Enum.map(shipped, fn attrs ->
          struct(
            %Template{is_system: true},
            Map.take(attrs, [:name, :subject, :text_body, :html_body])
          )
        end)

      plan = TemplateExport.plan(rows, shipped)

      assert plan.edited == []
      assert plan.files == []
      assert length(plan.untouched) == length(shipped)
    end
  end

  describe "write_files/2" do
    @tag :tmp_dir
    test "creates the directory tree and writes the content", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])

      assert [{^path, :written}] = TemplateExport.write_files([{path, "Confirm"}])
      assert File.read!(path) == "Confirm"
    end

    @tag :tmp_dir
    test "refuses to overwrite a file a human already wrote", %{tmp_dir: dir} do
      # A re-run, or an export onto a host that already hand-wrote an override,
      # must never silently replace it.
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :skipped}] = TemplateExport.write_files([{path, "from the database"}])
      assert File.read!(path) == "hand-written"
    end

    @tag :tmp_dir
    test "overwrites only when explicitly forced", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :written}] =
               TemplateExport.write_files([{path, "from the database"}], force: true)

      assert File.read!(path) == "from the database"
    end

    @tag :tmp_dir
    test "a dry run touches nothing", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])

      assert [{^path, :would_write}] =
               TemplateExport.write_files([{path, "Confirm"}], dry_run: true)

      refute File.exists?(path)
    end

    @tag :tmp_dir
    test "a dry run still reports a pre-existing file as skipped", %{tmp_dir: dir} do
      # So --dry-run tells the truth about what a real run would do.
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :skipped}] = TemplateExport.write_files([{path, "x"}], dry_run: true)
    end
  end
end
