defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqsTest do
  @moduledoc """
  Unit tests for the "Amazon SES & SQS" settings section's SES-credentials
  source selector (ported from the old routable Settings LiveView, Stage
  B3 / Stage 1 A5). This package ships no Endpoint/Router, so there's no
  `Phoenix.LiveViewTest` harness available standalone — the callback is
  exercised directly against a hand-built socket instead, same as it would
  run inside the real live_component process.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs, as: SesSection
  alias PhoenixKit.Settings

  # Minimal socket that supports assign/3 and put_flash/3 without a live
  # connection or Endpoint.
  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  describe "handle_event(\"assign_aws_integration\", ...)" do
    test "persists the chosen connection uuid to emails_aws_integration_uuid" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "primary")

      assert {:noreply, socket} =
               SesSection.handle_event(
                 "assign_aws_integration",
                 %{"uuid" => uuid},
                 bare_socket()
               )

      assert socket.assigns.selected_aws_integration_uuid == uuid
      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
    end

    test "can be switched back to legacy (empty uuid)" do
      Settings.update_setting("emails_aws_integration_uuid", "some-uuid")

      assert {:noreply, socket} =
               SesSection.handle_event("assign_aws_integration", %{"uuid" => ""}, bare_socket())

      assert socket.assigns.selected_aws_integration_uuid == ""
      assert Settings.get_setting("emails_aws_integration_uuid") == nil
    end
  end

  describe "the section renders" do
    test "with no AWS pipeline settings at all" do
      html = render_section()

      assert html =~ "Per-account event tracking"
      refute html =~ "Inherited settings"
    end

    test "with legacy settings present — the state that used to crash the page" do
      # The legacy note is only rendered when these are set, so a component test
      # on a clean database never reached it: the accordion was called with a
      # `title` attribute where a slot is required, and the whole settings page
      # went down for exactly the installs the note is written for.
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_ses_configuration_set("legacy-set")

      html = render_section()

      assert html =~ "Inherited settings"
      assert html =~ "legacy-set"
    end

    test "the events status line follows what actually gates collection" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(false)

      html = render_section()

      # `email_ses_events` alone used to drive this line, so it claimed
      # collection was on while the tracker was off.
      assert html =~ "collection is off"
    end
  end

  defp render_section do
    render_component(SesSection, %{id: "aws"}, endpoint: PhoenixKitEmails.Test.StubEndpoint)
  end
end
