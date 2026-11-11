defmodule PhoenixKit.Modules.Emails.TemplateExportDBTest do
  @moduledoc """
  The classification against rows that have actually round-tripped through
  JSONB — the link the struct-level tests cannot cover.
  """
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKitEmails.Test.LegacyTemplates
  alias PhoenixKitEmails.Test.Repo

  test "a seeded row loaded back from the database is not reported as edited" do
    # If JSONB decoding produced maps that compared unequal to the shipped
    # defaults, every install would export every template and an operator's
    # real edits would be buried in noise. This is the only place that link is
    # exercised.
    LegacyTemplates.seed!()

    shipped = Templates.default_system_templates()
    stored = Templates.list_templates()

    assert stored != [], "expected the seed to have inserted rows"

    plan = TemplateExport.plan(stored, shipped)

    assert plan.edited == [],
           "freshly seeded rows reported as edited: " <>
             Enum.map_join(plan.edited, ", ", & &1.name)

    assert plan.files == []
  end

  @tag :tmp_dir
  test "an edited row exports files whose content is the operator's", %{tmp_dir: dir} do
    LegacyTemplates.seed!()

    template = LegacyTemplates.get!("register")
    LegacyTemplates.update!(template, %{subject: %{"en" => "Please confirm"}})

    plan =
      TemplateExport.plan(
        Templates.list_templates(),
        Templates.default_system_templates(),
        out: dir
      )

    assert [%{name: "register"}] = plan.edited

    TemplateExport.write_files(plan.files)

    assert File.read!(Path.join([dir, "register", "subject.txt"])) == "Please confirm"
  end

  describe "active_template/1" do
    test "reads the active row by name, and only an active one" do
      LegacyTemplates.seed!()

      assert %{name: "register"} = TemplateExport.active_template("register")

      LegacyTemplates.update!(LegacyTemplates.get!("register"), %{status: "draft"})
      assert TemplateExport.active_template("register") == nil
      assert TemplateExport.active_template("no_such_template") == nil
    end

    test "answers nil when the table is absent" do
      refute Templates.legacy_table_exists?()
      assert TemplateExport.active_template("register") == nil
    end
  end

  test "the legacy table is absent unless a test builds it, and listing it is empty" do
    refute Templates.legacy_table_exists?()
    assert Templates.list_templates() == []
  end

  describe "legacy table schema lookup" do
    test "finds a named-schema table outside the search path" do
      LegacyTemplates.create_table!()
      Repo.query!(~s(CREATE SCHEMA "Legacy ""Templates"))

      Repo.query!(
        ~s(ALTER TABLE public.phoenix_kit_email_templates SET SCHEMA "Legacy ""Templates")
      )

      assert Templates.legacy_table_exists?(~s(Legacy "Templates))
      refute Templates.legacy_table_exists?("public")
      refute Templates.legacy_table_exists?()
    end

    test "a table on the search path does not count for another schema" do
      LegacyTemplates.create_table!()
      Repo.query!("CREATE SCHEMA legacy_templates_scratch")

      assert Templates.legacy_table_exists?()
      refute Templates.legacy_table_exists?("legacy_templates_scratch")
      refute Templates.legacy_table_exists?("missing_schema")
    end

    test "an unconfigured prefix keeps search-path resolution" do
      LegacyTemplates.seed!()
      Repo.query!("CREATE SCHEMA legacy_templates_scratch")

      Repo.query!(
        "ALTER TABLE public.phoenix_kit_email_templates SET SCHEMA legacy_templates_scratch"
      )

      Repo.query!("SET LOCAL search_path TO legacy_templates_scratch, public")

      assert Templates.legacy_table_exists?()
      assert Enum.any?(Templates.list_templates(), &(&1.name == "register"))
      assert %{name: "register"} = TemplateExport.active_template("register")
    end
  end
end
