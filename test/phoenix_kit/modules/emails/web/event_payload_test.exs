defmodule PhoenixKit.Modules.Emails.Web.EventPayloadTest do
  @moduledoc """
  A LiveView event payload is whatever the client sends, and a crafted event
  can put an integer, `nil` or a map where the template would put a string.
  These handlers used to pass the value straight to `String.*`,
  `Date.from_iso8601/1` or `String.to_atom/1`, so the wrong shape raised and
  took the LiveView down — and `String.to_atom/1` grew the atom table with
  every new value. Each one must now refuse the payload and carry on.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.Web.Blocklist
  alias PhoenixKit.Modules.Emails.Web.Emails, as: EmailsLive
  alias PhoenixKit.Modules.Emails.Web.Metrics
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor
  alias PhoenixKit.Modules.Emails.Web.Templates, as: TemplatesLive

  @non_strings [42, nil, %{"a" => "b"}, ["x"]]

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  describe "Metrics change_period" do
    defp metrics_socket do
      {:ok, socket} = Metrics.mount(%{}, %{}, bare_socket())
      socket
    end

    test "a listed period is applied" do
      {:noreply, socket} =
        Metrics.handle_event("change_period", %{"period" => "last_30_days"}, metrics_socket())

      assert socket.assigns.period == :last_30_days
    end

    test "an unknown period keeps the current one and creates no atom" do
      name = "no_such_period_#{System.unique_integer([:positive])}"

      {:noreply, socket} =
        Metrics.handle_event("change_period", %{"period" => name}, metrics_socket())

      assert socket.assigns.period == :last_7_days
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "\"custom\" is not a period this event can pick" do
      {:noreply, socket} =
        Metrics.handle_event("change_period", %{"period" => "custom"}, metrics_socket())

      assert socket.assigns.period == :last_7_days
    end

    for value <- @non_strings do
      test "a #{inspect(value)} period keeps the current one" do
        {:noreply, socket} =
          Metrics.handle_event(
            "change_period",
            %{"period" => unquote(Macro.escape(value))},
            metrics_socket()
          )

        assert socket.assigns.period == :last_7_days
      end
    end

    test "a non-string custom range is refused with a flash" do
      {:noreply, socket} =
        Metrics.handle_event(
          "apply_custom_range",
          %{"start_date" => 20_260_101, "end_date" => nil},
          metrics_socket()
        )

      assert socket.assigns.flash["error"]
      assert socket.assigns.period == :last_7_days
    end
  end

  describe "S3 settings" do
    defp s3_socket do
      bare_socket(%{
        email_archive_to_s3: false,
        email_s3_bucket: "kept-bucket",
        email_s3_integration: "kept-uuid"
      })
    end

    for value <- [42, %{"a" => "b"}, ["x"]] do
      test "a #{inspect(value)} bucket is refused and the stored one kept" do
        {:ok, _} = Emails.set_s3_bucket("kept-bucket")

        {:noreply, socket} =
          EmailTracking.handle_event(
            "update_s3_bucket",
            %{"value" => unquote(Macro.escape(value))},
            s3_socket()
          )

        assert socket.assigns.flash["error"]
        assert socket.assigns.email_s3_bucket == "kept-bucket"
        assert Emails.get_s3_bucket() == "kept-bucket"
      end

      test "a #{inspect(value)} connection is refused and the stored one kept" do
        {:ok, _} = Emails.set_s3_integration("kept-uuid")

        {:noreply, socket} =
          EmailTracking.handle_event(
            "update_s3_integration",
            %{"value" => unquote(Macro.escape(value))},
            s3_socket()
          )

        assert socket.assigns.flash["error"]
        assert socket.assigns.email_s3_integration == "kept-uuid"
        assert Emails.get_s3_integration() == "kept-uuid"
      end
    end
  end

  describe "Blocklist" do
    test "a non-string email is refused with a flash and nothing is blocked" do
      {:noreply, socket} =
        Blocklist.handle_event(
          "add_block",
          %{"email" => 42, "reason" => "manual", "expires_at" => ""},
          bare_socket()
        )

      assert socket.assigns.flash["error"]
      assert RateLimiter.list_blocklist(%{}) == []
    end

    test "a non-string expiry is ignored and the address blocked without one" do
      email = "payload-#{System.unique_integer([:positive])}@example.com"

      {:noreply, _socket} =
        Blocklist.handle_event(
          "add_block",
          %{"email" => email, "reason" => "manual", "expires_at" => 20_260_101},
          blocklist_socket()
        )

      assert [%{email: ^email, expires_at: nil}] = RateLimiter.list_blocklist(%{})
    end

    # Already safe — import_blocklist_csv/1 rescues — but pinned with the rest.
    test "a non-string CSV import is refused with a flash" do
      {:noreply, socket} =
        Blocklist.handle_event("import_csv", %{"csv_content" => 42}, blocklist_socket())

      assert socket.assigns.flash["error"]
      refute socket.assigns.flash["info"]
    end
  end

  describe "Emails list" do
    test "a non-string search query is dropped, not trimmed" do
      {:noreply, socket} =
        EmailsLive.handle_event("filter", %{"search" => %{"query" => 42}}, emails_socket())

      assert {:live, :patch, %{to: to}} = socket.redirected
      refute to =~ "search="
    end

    test "a non-string test recipient is a validation error" do
      {:noreply, socket} =
        EmailsLive.handle_event(
          "validate_test_email",
          %{"test_email" => %{"recipient" => 42}},
          emails_socket()
        )

      assert socket.assigns.test_email_form.errors.recipient
    end

    test "a non-string column order keeps the working copy" do
      socket =
        emails_socket()
        |> Phoenix.Component.assign(:temp_selected_columns, ["to", "status", "actions"])

      {:noreply, socket} =
        EmailsLive.handle_event("update_table_columns", %{"column_order" => 42}, socket)

      assert socket.assigns.selected_columns == ["to", "status", "actions"]
    end
  end

  describe "Templates list" do
    test "a non-string search query is dropped, not trimmed" do
      {:noreply, socket} =
        TemplatesLive.handle_event("filter", %{"search" => %{"query" => 42}}, templates_socket())

      assert {:live, :patch, %{to: to}} = socket.redirected
      refute to =~ "search="
    end

    test "a non-string clone name and display name are validation errors" do
      {:noreply, socket} =
        TemplatesLive.handle_event(
          "validate_clone",
          %{"clone" => %{"name" => 42, "display_name" => %{"en" => "x"}}},
          templates_socket()
        )

      assert socket.assigns.clone_form.errors.name
      assert socket.assigns.clone_form.errors.display_name
    end
  end

  describe "Template editor" do
    test "a non-string test recipient is a validation error" do
      socket =
        bare_socket(%{test_form: %{recipient: "", sample_variables: %{}, errors: %{}}})

      {:noreply, socket} =
        TemplateEditor.handle_event("validate_test", %{"test" => %{"recipient" => 42}}, socket)

      assert socket.assigns.test_form.errors.recipient
    end
  end

  defp blocklist_socket do
    bare_socket(%{
      search_term: "",
      reason_filter: "",
      status_filter: "all",
      sort_by: :inserted_at,
      sort_dir: :desc,
      page: 1,
      per_page: 50,
      selected_emails: [],
      show_add_form: true,
      show_import_form: true
    })
  end

  defp emails_socket do
    {:ok, socket} = EmailsLive.mount(%{}, %{}, bare_socket())
    socket
  end

  defp templates_socket do
    {:ok, socket} = TemplatesLive.mount(%{}, %{}, bare_socket())
    socket
  end
end
