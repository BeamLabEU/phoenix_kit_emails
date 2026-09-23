defmodule PhoenixKit.Modules.Emails.TemplatesTest do
  @moduledoc """
  Context-level coverage for the reserved-name guard: `create_template/1`
  must reject a reserved name without `is_system: true`, and the legitimate
  path (`seed_system_templates/0`, which always passes `is_system: true`)
  must keep working.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Templates

  describe "create_template/1 reserved name guard" do
    test "rejects an unseeded reserved name without is_system: true" do
      assert {:error, changeset} =
               Templates.create_template(%{
                 name: "new_login_alert",
                 slug: "new-login-alert",
                 display_name: %{"en" => "New Login Alert"},
                 subject: %{"en" => "New login detected"},
                 html_body: %{"en" => "<p>Hi</p>"},
                 text_body: %{"en" => "Hi"},
                 category: "system",
                 status: "active"
               })

      assert {msg, _} = Keyword.get(changeset.errors, :name)
      assert msg =~ "reserved"
      assert Templates.get_template_by_name("new_login_alert") == nil
    end
  end

  describe "seed_system_templates/0" do
    test "still succeeds now that reserved names are guarded" do
      assert {:ok, templates} = Templates.seed_system_templates()

      assert length(templates) == length(Templates.default_system_templates())
      assert Enum.all?(templates, & &1.is_system)
    end
  end
end
