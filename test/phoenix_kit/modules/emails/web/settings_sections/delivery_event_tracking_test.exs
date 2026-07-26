defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTrackingTest do
  @moduledoc """
  Unit tests for the unified "Delivery event tracking" admin panel (task
  #56 P2, spec §5) — `update/2`'s registry-driven rows (one per state)
  and every `handle_event/3` action. Like `AmazonSesSqsTest`, this
  package ships no Endpoint/Router, so there's no `Phoenix.LiveViewTest`
  harness — callbacks are exercised directly against a hand-built socket.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking, as: Panel
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp create_ses_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "secret"
      })

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  defp create_brevo_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  defp row_for(rows, provider_kind), do: Enum.find(rows, &(&1.provider_kind == provider_kind))

  describe "update/2 — the registry-driven rows" do
    test "one row per registered tracker, :off by default (nothing enabled)" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert length(socket.assigns.rows) == 2
      assert row_for(socket.assigns.rows, "aws_ses").state == :off
      assert row_for(socket.assigns.rows, "brevo_api").state == :off
    end

    test "enabled but no matching integration: :idle_no_integration" do
      {:ok, _} = Emails.set_sqs_polling(true)

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "aws_ses").state == :idle_no_integration
    end

    test "enabled + eligible + a chain queued: :active" do
      create_ses_profile()
      {:ok, %Oban.Job{}} = SQSPollingManager.enable_polling()

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      row = row_for(socket.assigns.rows, "aws_ses")
      assert row.state == :active
      assert row.pending_jobs > 0
    end

    test "enabled + eligible but zero queued jobs: :stalled" do
      create_ses_profile()
      {:ok, _} = Emails.set_sqs_polling(true)

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "aws_ses").state == :stalled
    end

    test "Brevo row exposes an accounts list, SES row does not" do
      create_brevo_profile()

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "brevo_api").accounts != nil
      assert row_for(socket.assigns.rows, "aws_ses").accounts == nil
    end
  end

  describe "handle_event(\"toggle_tracking\", ...)" do
    test "turns SES polling on, then off again" do
      refute Emails.sqs_polling_enabled?()

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, bare_socket())

      assert Emails.sqs_polling_enabled?()
      assert row_for(socket.assigns.rows, "aws_ses").enabled

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, socket)

      refute Emails.sqs_polling_enabled?()
      refute row_for(socket.assigns.rows, "aws_ses").enabled
    end

    test "turns Brevo polling on" do
      refute Emails.brevo_events_enabled?()

      assert {:noreply, _socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "brevo_api"}, bare_socket())

      assert Emails.brevo_events_enabled?()
    end
  end

  describe "handle_event(\"poll_now\", ...)" do
    test "inserts an immediate job for the SES worker" do
      assert {:noreply, _socket} =
               Panel.handle_event("poll_now", %{"provider" => "aws_ses"}, bare_socket())

      worker = SQSPollingJob.worker_name()
      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
    end

    test "inserts an immediate job for the Brevo worker" do
      assert {:noreply, _socket} =
               Panel.handle_event("poll_now", %{"provider" => "brevo_api"}, bare_socket())

      worker = BrevoPollingJob.worker_name()
      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
    end
  end

  describe "handle_event(\"restart\", ...)" do
    test "reconciles a stalled tracker back to a queued chain" do
      create_ses_profile()
      {:ok, _} = Emails.set_sqs_polling(true)

      worker = SQSPollingJob.worker_name()
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))

      assert {:noreply, socket} =
               Panel.handle_event("restart", %{"provider" => "aws_ses"}, bare_socket())

      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
      assert row_for(socket.assigns.rows, "aws_ses").state == :active
    end

    test "a tracker that should not run stays stopped (:not_running, not an error)" do
      assert {:noreply, socket} =
               Panel.handle_event("restart", %{"provider" => "aws_ses"}, bare_socket())

      assert socket.assigns.flash["error"] == nil
    end
  end

  describe "handle_event(\"update_interval\", ...)" do
    test "accepts a valid interval" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "5000"},
                 bare_socket()
               )

      assert Emails.get_sqs_config().polling_interval_ms == 5_000
      assert socket.assigns.flash["error"] == nil
    end

    test "rejects a value below the tracker's own minimum" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "10"},
                 bare_socket()
               )

      # Regression for P2 dual-review fix 4/5: the manager's own reason
      # string used to get double-quoted by inspect/1 before landing in
      # the flash.
      assert error = socket.assigns.flash["error"]
      refute error =~ "\""
    end

    test "rejects a non-numeric value without raising" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "not-a-number"},
                 bare_socket()
               )

      assert socket.assigns.flash["error"]
    end
  end

  describe "handle_event(\"toggle_account\", ...)" do
    test "excludes then re-includes a Brevo account from polling" do
      create_brevo_profile()
      [{uuid, _name, true}] = BrevoPollingManager.accounts()

      assert {:noreply, socket} =
               Panel.handle_event(
                 "toggle_account",
                 %{"provider" => "brevo_api", "uuid" => uuid},
                 bare_socket()
               )

      assert [{^uuid, _name, false}] = row_for(socket.assigns.rows, "brevo_api").accounts

      assert {:noreply, socket} =
               Panel.handle_event(
                 "toggle_account",
                 %{"provider" => "brevo_api", "uuid" => uuid},
                 socket
               )

      assert [{^uuid, _name, true}] = row_for(socket.assigns.rows, "brevo_api").accounts
    end
  end

  describe "an unknown provider_kind (P2 dual-review fix 5b)" do
    test "every action returns {:noreply, socket} instead of raising" do
      socket = bare_socket()

      for {event, params} <- [
            {"toggle_tracking", %{"provider" => "does-not-exist"}},
            {"poll_now", %{"provider" => "does-not-exist"}},
            {"restart", %{"provider" => "does-not-exist"}},
            {"update_interval", %{"provider" => "does-not-exist", "interval" => "5000"}},
            {"toggle_account", %{"provider" => "does-not-exist", "uuid" => "any-uuid"}}
          ] do
        assert {:noreply, %Phoenix.LiveView.Socket{}} = Panel.handle_event(event, params, socket)
      end
    end
  end
end
