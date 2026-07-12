defmodule PhoenixKit.Modules.Emails.Web.SettingsTest do
  @moduledoc """
  Unit tests for the emails Settings LiveView's SES-credentials-source
  selector (Stage B, B3). This package ships no Endpoint/Router, so
  there's no `Phoenix.LiveViewTest` harness available standalone — the
  callback is exercised directly against a hand-built socket instead,
  same as it would run inside the real LiveView process.
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails.Web.Settings, as: SettingsLive
  alias PhoenixKit.Settings

  # Minimal socket that supports assign/3 and put_flash/3 without a live
  # connection or Endpoint.
  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  describe "handle_event(\"select_aws_integration\", ...)" do
    test "persists the chosen connection uuid to emails_aws_integration_uuid" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "primary")

      assert {:noreply, socket} =
               SettingsLive.handle_event(
                 "select_aws_integration",
                 %{"uuid" => uuid},
                 bare_socket()
               )

      assert socket.assigns.selected_aws_integration_uuid == uuid
      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
    end

    test "can be switched back to legacy (empty uuid)" do
      Settings.update_setting("emails_aws_integration_uuid", "some-uuid")

      assert {:noreply, socket} =
               SettingsLive.handle_event("select_aws_integration", %{"uuid" => ""}, bare_socket())

      assert socket.assigns.selected_aws_integration_uuid == ""
      assert Settings.get_setting("emails_aws_integration_uuid") == nil
    end
  end
end
