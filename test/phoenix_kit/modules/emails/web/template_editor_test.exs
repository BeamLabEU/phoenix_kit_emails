defmodule PhoenixKit.Modules.Emails.Web.TemplateEditorTest do
  @moduledoc """
  The "New Template" form never sends `is_system` (it only appears as
  `disabled=` on system rows being edited, and disabled fields aren't
  submitted), so this is the LiveView-side check that the changeset's
  reserved-name guard (`PhoenixKit.Modules.Emails.Template`) actually blocks
  the save and surfaces a readable error, not just that the context function
  does.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor

  defp bare_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp reserved_params(name) do
    %{
      "name" => name,
      "slug" => String.replace(name, "_", "-"),
      "display_name" => %{"en" => "Some Display Name"},
      "subject" => %{"en" => "A subject"},
      "html_body" => %{"en" => "<p>Hi</p>"},
      "text_body" => %{"en" => "Hi"},
      "category" => "system",
      "status" => "draft"
    }
  end

  test "save on a :new socket rejects an unseeded reserved name and does not create a template" do
    socket = bare_socket(%{mode: :new, saving: false, template: nil})

    assert {:noreply, updated} =
             TemplateEditor.handle_event(
               "save",
               %{"email_template" => reserved_params("new_login_alert"), "save_as" => "active"},
               socket
             )

    assert updated.assigns.saving == false
    refute Map.has_key?(updated.assigns.flash, "info")

    changeset = updated.assigns.changeset
    refute changeset.valid?
    assert {msg, _} = Keyword.get(changeset.errors, :name)
    assert msg =~ "reserved"

    # Not created.
    assert Templates.get_template_by_name("new_login_alert") == nil
  end
end
