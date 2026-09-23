defmodule PhoenixKit.Modules.Emails.Web.TemplatesTest do
  @moduledoc """
  Archiving a system template used to be blocked outright, while activating
  one worked silently with no confirmation — an asymmetry between "off" and
  "on". This locks in the fix: both actions are now allowed for system rows,
  but go through the confirmation modal first (reusing the same mechanism
  `request_delete` already uses), while non-system rows keep the old
  immediate behavior. Delete stays untouched and still rejected for system
  rows.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.Templates, as: TemplatesLive

  defp bare_socket(assigns \\ %{}) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      filters: %{search: "", category: "", status: "", is_system: ""},
      page: 1,
      per_page: 25,
      sort_by: :inserted_at,
      sort_dir: :desc,
      confirmation_modal: %{show: false}
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp create_system_template(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %{
      name: "sys_template_#{n}",
      slug: "sys-template-#{n}",
      display_name: %{"en" => "System Template #{n}"},
      subject: %{"en" => "Subject"},
      html_body: %{"en" => "<p>Hi</p>"},
      text_body: %{"en" => "Hi"},
      category: "system",
      status: "active",
      is_system: true
    }

    {:ok, template} = Templates.create_template(Map.merge(base, attrs))
    template
  end

  defp create_custom_template(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %{
      name: "custom_template_#{n}",
      slug: "custom-template-#{n}",
      display_name: %{"en" => "Custom Template #{n}"},
      subject: %{"en" => "Subject"},
      html_body: %{"en" => "<p>Hi</p>"},
      text_body: %{"en" => "Hi"},
      category: "transactional",
      status: "active",
      is_system: false
    }

    {:ok, template} = Templates.create_template(Map.merge(base, attrs))
    template
  end

  describe "request_archive" do
    test "on a system template populates the confirmation modal and does not archive yet" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_archive", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "archive_template"
      assert updated.assigns.confirmation_modal.uuid == template.uuid

      assert Templates.get_template(template.uuid).status == "active"
    end

    test "on a non-system template archives immediately, no modal shown" do
      template = create_custom_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_archive", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal == %{show: false}
      assert Templates.get_template(template.uuid).status == "archived"
    end
  end

  describe "confirm_action archive_template" do
    test "actually archives the system template and hides the modal" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "confirm_action",
                 %{"action" => "archive_template", "uuid" => template.uuid},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == false
      assert Templates.get_template(template.uuid).status == "archived"
      assert updated.assigns.flash["info"] =~ template.name
    end
  end

  describe "request_activate" do
    test "on an archived system template populates the confirmation modal and does not activate yet" do
      template = create_system_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_activate", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "activate_template"
      assert updated.assigns.confirmation_modal.uuid == template.uuid

      assert Templates.get_template(template.uuid).status == "archived"
    end

    test "on a non-system archived template activates immediately, no modal shown" do
      template = create_custom_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_activate", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal == %{show: false}
      assert Templates.get_template(template.uuid).status == "active"
    end
  end

  describe "confirm_action activate_template" do
    test "actually activates the archived system template and hides the modal" do
      template = create_system_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "confirm_action",
                 %{"action" => "activate_template", "uuid" => template.uuid},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == false
      assert Templates.get_template(template.uuid).status == "active"
      assert updated.assigns.flash["info"] =~ template.name
    end
  end

  describe "delete still rejected for system templates (regression guard)" do
    test "request_delete still opens the modal unconditionally (unchanged behavior)" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "request_delete",
                 %{"uuid" => template.uuid, "name" => template.name},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "delete_template"
    end

    test "delete_template rejects a system template" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("delete_template", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.flash["error"] =~ "cannot be deleted"
      assert Templates.get_template(template.uuid) != nil
    end
  end

  describe "render" do
    test "Archive/Activate buttons appear for a system template row, Delete does not" do
      system_template = create_system_template()
      custom_template = create_custom_template()

      assigns = %{
        stats: Templates.get_template_stats(),
        loading: false,
        filters: %{search: "", category: "", status: "", is_system: ""},
        templates: [system_template, custom_template],
        display_locale: "en",
        sort_by: :inserted_at,
        sort_dir: :desc,
        page: 1,
        per_page: 25,
        total_count: 2,
        total_pages: 1,
        show_clone_modal: false,
        clone_template: nil,
        clone_form: %{name: "", display_name: "", errors: %{}},
        confirmation_modal: %{show: false}
      }

      html =
        render_component(&TemplatesLive.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      assert html =~ ~s|phx-value-uuid="#{system_template.uuid}"|
      assert html =~ "request_archive"

      # The system row's action group must not carry a delete button.
      refute html =~ ~s|phx-value-name="#{system_template.name}"|
      # The custom row still gets a delete button.
      assert html =~ ~s|phx-value-name="#{custom_template.name}"|
    end
  end
end
