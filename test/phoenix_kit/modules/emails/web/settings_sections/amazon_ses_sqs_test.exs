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

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs, as: SesSection
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking
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

      # The global save form submitted params its only handler clause did not
      # match, so every click killed the LiveView. Pin its absence.
      refute html =~ "aws-settings-form"
      refute html =~ "Save AWS Settings"
    end

    test "the global aws_* values are not shown even when they are set" do
      # They used to be rendered read-only in an "Inherited settings (legacy)"
      # accordion. The code fallback still reads them — poller and interceptor
      # are untouched — but an operator has no business seeing, let alone
      # reasoning about, a value only reachable from a per-account row.
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_ses_configuration_set("legacy-set")

      html = render_section()

      refute html =~ "Inherited settings"
      refute html =~ "legacy-set"
      refute html =~ "sqs.eu-north-1.amazonaws.com/1/q"

      # Still reads the globals under the hood — this is a UI removal only.
      assert Emails.get_sqs_queue_url() == "https://sqs.eu-north-1.amazonaws.com/1/q"
    end

    test "one tracked account, one still on offer" do
      {:ok, %{uuid: tracked}} = Integrations.add_connection("aws_ses", "tracked")
      {:ok, _} = Integrations.add_connection("aws_ses", "spare")
      {:ok, _} = Emails.set_aws_tracking(tracked, %{})

      html = render_section()

      assert html =~ "tracked"
      assert html =~ "Setup Infrastructure"
      assert html =~ "Unassign"
      # The picker for the connection that has no tracking row yet. Its label
      # rendered as "Accounts" until the fuzzy translation behind it was
      # fixed — `gettext.extract --merge` had matched it to the table column
      # of that name, and nothing rendered this button in a test.
      assert html =~ "Add account"
    end

    test "the SQS worker tuning knobs moved here, without the Performance Tips filler" do
      html = render_section()

      assert html =~ "SQS Worker Tuning"
      assert html =~ "Max Messages Per Poll"
      assert html =~ "Visibility Timeout"
      refute html =~ "Performance Tips"
    end

    test "warns while sending still runs on the global legacy credentials" do
      {:ok, _} = Settings.update_setting("aws_access_key_id", "AKIALEGACY")

      assert render_section() =~ "legacy credentials"
    end

    test "the events status line follows what actually gates collection" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(false)

      html = render_section()

      # `email_ses_events` alone used to drive this line, so it claimed
      # collection was on while the tracker was off.
      assert html =~ "collection is off"
    end

    test "and says so the other way round when collection really is running" do
      create_ses_connection_with_queue()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)

      html = render_section()

      assert html =~ "collection is on"
    end
  end

  # Everything `should_poll?/0` needs on the SES side: a connection, an enabled
  # send profile pointing at it, and a queue to poll.
  defp create_ses_connection_with_queue do
    {:ok, _} = Emails.enable_system()
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "collecting")

    {:ok, _} =
      Integrations.save_setup(uuid, %{"access_key" => "AKIATEST", "secret_key" => "secret"})

    {:ok, _} =
      SendProfiles.create_send_profile(%{
        name: "SES collecting",
        integration_uuid: uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
    uuid
  end

  defp render_section do
    render_component(SesSection, %{id: "aws"}, endpoint: PhoenixKitEmails.Test.StubEndpoint)
  end

  describe "the panel tells its row when it changed something" do
    test "a tracking change sends the parent an update" do
      uuid = create_ses_connection_with_queue()

      socket =
        bare_socket()
        |> Phoenix.Component.assign(:parent_id, "delivery-panel")
        |> Phoenix.Component.assign(:tracking_accounts, [])
        |> Phoenix.Component.assign(:setting_up_account, nil)
        |> Phoenix.Component.assign(
          :aws_ses_connections,
          Integrations.list_connections("aws_ses", owner: :any)
        )
        |> Phoenix.Component.assign(:selected_aws_integration_uuid, "")

      {:noreply, _socket} =
        SesSection.handle_event("assign_tracking_account", %{"uuid" => uuid}, socket)

      # send_update/2 posts to the calling process, which in a unit test is us:
      # the row above the panel learns about the new account instead of waiting
      # for something else to redraw it.
      assert_received {:phoenix, :send_update,
                       {{DeliveryEventTracking, "delivery-panel"}, %{id: "delivery-panel"}}}
    end
  end
end
