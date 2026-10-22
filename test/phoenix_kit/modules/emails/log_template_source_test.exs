defmodule PhoenixKit.Modules.Emails.LogTemplateSourceTest do
  @moduledoc """
  The log remembers which layer built the message (#48): `template_uuid` and
  `template_source` (`"db"` / `"file"` / `"module"`, `nil` without a template).
  Core hands the send path `:template_name` always and `:template_uuid` only
  when an active database row was used, so the layer is derived here.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Swoosh.Email

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.TemplateSources
  alias PhoenixKit.Modules.Emails.Web.SourceBadges
  alias PhoenixKitEmails.Test.Repo

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp email do
    new()
    |> to("recipient@example.com")
    |> from("sender@example.com")
    |> subject("Hello")
    |> text_body("Hi")
  end

  defp log_for(opts) do
    {:ok, log} = Interceptor.create_email_log(email(), opts)
    Repo.reload!(log)
  end

  @sources %{overrides: ["file_mail"], defaults: %{"module_mail" => nil, "file_mail" => nil}}

  describe "TemplateSources.origin/3" do
    test "a uuid means a database row, whatever else exists for the name" do
      assert TemplateSources.origin("file_mail", Ecto.UUID.generate(), @sources) == "db"
    end

    test "no uuid and a file override for the name means the file" do
      assert TemplateSources.origin("file_mail", nil, @sources) == "file"
    end

    test "no uuid and no override means the module default" do
      assert TemplateSources.origin("module_mail", nil, @sources) == "module"
      assert TemplateSources.origin("caller_default_mail", nil, @sources) == "module"
    end

    test "a message without a template has no source" do
      assert TemplateSources.origin(nil, nil, @sources) == nil
      assert TemplateSources.origin("", nil, @sources) == nil
    end
  end

  describe "the interceptor stamps the log" do
    test "an active row: template_uuid and source db" do
      uuid = Ecto.UUID.generate()
      log = log_for(template_name: "row_mail", template_uuid: uuid, template_sources: @sources)

      assert log.template_name == "row_mail"
      assert log.template_uuid == uuid
      assert log.template_source == "db"
    end

    test "a host file override: source file, no uuid" do
      log = log_for(template_name: "file_mail", template_sources: @sources)

      assert log.template_uuid == nil
      assert log.template_source == "file"
    end

    test "the module default: source module, no uuid" do
      log = log_for(template_name: "module_mail", template_sources: @sources)

      assert log.template_uuid == nil
      assert log.template_source == "module"
    end

    test "the module default also when the layers are read from core" do
      log = log_for(template_name: "no_such_mail_#{System.unique_integer([:positive])}")

      assert log.template_source == "module"
    end

    test "no template: both stay nil" do
      log = log_for([])

      assert log.template_name == nil
      assert log.template_uuid == nil
      assert log.template_source == nil
    end

    test "a source named by the caller (a core that reports the layer) wins" do
      log =
        log_for(template_name: "module_mail", template_source: "file", template_sources: @sources)

      assert log.template_source == "file"
    end

    test "an unknown source from the caller is ignored" do
      log =
        log_for(
          template_name: "module_mail",
          template_source: "bogus",
          template_sources: @sources
        )

      assert log.template_source == "module"
    end

    test "the changeset refuses a source that is not one of the three" do
      changeset =
        Log.changeset(%Log{}, %{
          message_id: "m",
          to: "a@example.com",
          from: "b@example.com",
          template_source: "bogus"
        })

      assert Keyword.has_key?(changeset.errors, :template_source)
    end
  end

  describe "the details badge" do
    defp badge(attrs) do
      render_component(
        &SourceBadges.log_source/1,
        Keyword.merge([log: struct(Log, attrs), template_exists?: false], [])
      )
    end

    test "db: a badge and a link to the row" do
      uuid = Ecto.UUID.generate()

      html =
        render_component(&SourceBadges.log_source/1,
          log: %Log{template_name: "row_mail", template_source: "db", template_uuid: uuid},
          template_exists?: true
        )

      assert html =~ "Database template"
      assert html =~ "/admin/emails/templates/#{uuid}/edit"
    end

    test "db: no link once the row is gone" do
      html =
        badge(
          template_name: "row_mail",
          template_source: "db",
          template_uuid: Ecto.UUID.generate()
        )

      assert html =~ "Database template"
      refute html =~ "/edit"
    end

    test "file and module get their own badge and no link" do
      assert badge(template_name: "x", template_source: "file") =~ "File override"
      assert badge(template_name: "x", template_source: "module") =~ "Module default"
      refute badge(template_name: "x", template_source: "file") =~ "<a "
    end

    test "nothing for a log without a source" do
      assert badge(template_name: nil, template_source: nil) |> String.trim() == ""
    end
  end
end
