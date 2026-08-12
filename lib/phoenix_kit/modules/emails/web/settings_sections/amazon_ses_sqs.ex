defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs do
  @moduledoc """
  "Amazon SES & SQS" section on the core Email Sending settings page
  (`/admin/settings/email-sending`).

  Covers the module's SES-specific concerns: which Integrations connection
  (or legacy manual credentials) supplies SES/SQS credentials, event
  tracking, one-click infrastructure setup, and the SQS polling worker.
  Contributed via `PhoenixKit.Modules.Emails.email_settings_sections/0`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.AWS.InfrastructureSetup
  alias PhoenixKit.Config.AWS
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Settings

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :aws_settings) do
        socket
      else
        email_config = Emails.get_config()

        aws_settings = %{
          access_key_id: Settings.get_setting("aws_access_key_id", ""),
          secret_access_key: Settings.get_setting("aws_secret_access_key", ""),
          region: Settings.get_setting("aws_region", ""),
          sqs_queue_url: Settings.get_setting("aws_sqs_queue_url", ""),
          sqs_dlq_url: Settings.get_setting("aws_sqs_dlq_url", ""),
          sqs_queue_arn: Settings.get_setting("aws_sqs_queue_arn", ""),
          sns_topic_arn: Settings.get_setting("aws_sns_topic_arn", ""),
          ses_configuration_set: Settings.get_setting("aws_ses_configuration_set", "")
        }

        socket
        |> assign(:mailer_status, Utils.mailer_adapter_status())
        |> assign(:current_provider, Emails.current_provider())
        |> assign(:aws_configured, Emails.aws_configured?())
        |> assign(:email_ses_events, email_config.ses_events)
        |> assign(:sqs_max_messages_per_poll, email_config.sqs_max_messages_per_poll)
        |> assign(:sqs_visibility_timeout, email_config.sqs_visibility_timeout)
        |> assign(:aws_settings, aws_settings)
        |> assign(:aws_ses_connections, Integrations.list_connections("aws_ses"))
        |> assign(
          :selected_aws_integration_uuid,
          Settings.get_setting("emails_aws_integration_uuid", "")
        )
        |> assign(:saving, false)
        |> assign(:setting_up_aws, false)
        |> assign(:verifying_credentials, false)
        |> assign(:credential_verification_status, :pending)
        |> assign(:credential_verification_message, "")
        |> assign(:aws_permissions, %{})
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_email_ses_events", _params, socket) do
    new_ses_events = !socket.assigns.email_ses_events

    case Emails.set_ses_events(new_ses_events) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_ses_events, new_ses_events)
          |> put_flash(
            :info,
            if(new_ses_events,
              do: gettext("AWS SES events tracking enabled"),
              else: gettext("AWS SES events tracking disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update AWS SES events tracking"))
        {:noreply, socket}
    end
  end

  def handle_event("update_max_messages", params, socket) do
    value = Map.get(params, "max_messages") || Map.get(params, "value")

    case Integer.parse(value) do
      {max_messages, _} when max_messages >= 1 and max_messages <= 10 ->
        case Emails.set_sqs_max_messages(max_messages) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_max_messages_per_poll, max_messages)
              |> put_flash(
                :info,
                gettext("SQS max messages updated to %{count}", count: max_messages)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update SQS max messages"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(socket, :error, gettext("Please enter a valid number between 1 and 10"))

        {:noreply, socket}
    end
  end

  def handle_event("update_visibility_timeout", params, socket) do
    value = Map.get(params, "timeout") || Map.get(params, "value")

    case Integer.parse(value) do
      {timeout, _} when timeout >= 30 and timeout <= 43_200 ->
        case Emails.set_sqs_visibility_timeout(timeout) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_visibility_timeout, timeout)
              |> put_flash(
                :info,
                gettext("SQS visibility timeout updated to %{seconds} seconds", seconds: timeout)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update SQS visibility timeout"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Please enter a valid number between 30 and 43200 seconds")
          )

        {:noreply, socket}
    end
  end

  def handle_event("setup_aws_infrastructure", _params, socket) do
    socket = assign(socket, :setting_up_aws, true)

    project_name =
      Settings.get_setting("project_title", "myapp")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    # Resolved credentials: the assigned Integrations connection first, then
    # the legacy settings fallback — the form no longer carries credentials.
    region = Emails.get_aws_region() || AWS.region()

    access_key_id =
      case Emails.get_aws_access_key() do
        key when is_binary(key) and key != "" -> key
        _ -> nil
      end

    secret_access_key =
      case Emails.get_aws_secret_key() do
        key when is_binary(key) and key != "" -> key
        _ -> nil
      end

    if access_key_id && secret_access_key do
      case InfrastructureSetup.run(
             project_name: project_name,
             region: region,
             access_key_id: access_key_id,
             secret_access_key: secret_access_key
           ) do
        {:ok, config} ->
          case Settings.update_settings_batch(config) do
            {:ok, _results} ->
              new_aws_settings = %{
                access_key_id: access_key_id,
                secret_access_key: secret_access_key,
                region: config["aws_region"],
                sqs_queue_url: config["aws_sqs_queue_url"],
                sqs_dlq_url: config["aws_sqs_dlq_url"],
                sqs_queue_arn: config["aws_sqs_queue_arn"],
                sns_topic_arn: config["aws_sns_topic_arn"],
                ses_configuration_set: config["aws_ses_configuration_set"]
              }

              socket =
                socket
                |> assign(:aws_settings, new_aws_settings)
                |> assign(:setting_up_aws, false)
                |> put_flash(:info, """
                ✅ AWS Email Infrastructure Created Successfully!

                📦 Created Resources:
                • Project: #{project_name}
                • Region: #{config["aws_region"]}
                • SNS Topic: #{config["aws_sns_topic_arn"]}
                • SQS Queue: #{config["aws_sqs_queue_url"]}
                • Dead Letter Queue: #{config["aws_sqs_dlq_url"]}
                • SES Configuration Set: #{config["aws_ses_configuration_set"]}

                🎉 All settings have been automatically filled below.
                Click "Save AWS Settings" to persist the configuration.

                ⚡ Next steps:
                1. Verify your email/domain in AWS SES Console
                2. Turn on tracking for Amazon SES in the "Delivery Event Tracking" section above
                3. Start sending emails!
                """)

              {:noreply, socket}

            {:error, _failed_operation, _failed_value, _changes} ->
              socket =
                socket
                |> assign(:setting_up_aws, false)
                |> put_flash(:error, """
                ⚠️ Infrastructure created but failed to save settings.

                AWS resources were created successfully, but there was an error saving configuration to database.
                Please save AWS settings manually.
                """)

              {:noreply, socket}
          end

        {:error, step, reason} ->
          socket =
            socket
            |> assign(:setting_up_aws, false)
            |> put_flash(:error, """
            ❌ AWS Setup Failed

            Failed at step: #{step}
            Reason: #{reason}

            Please check:
            • AWS credentials are valid
            • IAM permissions (SQS, SNS, SES, STS)
            • AWS region is correct
            • No resource limits exceeded

            You can also use the manual bash script:
            ./scripts/setup_aws_email_infrastructure.sh
            """)

          {:noreply, socket}
      end
    else
      socket =
        socket
        |> assign(:setting_up_aws, false)
        |> put_flash(:error, """
        ❌ AWS Credentials Required

        Please configure AWS Access Key ID and Secret Access Key before running setup.

        You can get these credentials from AWS IAM Console:
        https://console.aws.amazon.com/iam/home#/users
        """)

      {:noreply, socket}
    end
  end

  def handle_event("save_aws_settings", %{"aws_settings" => aws_params}, socket) do
    socket = assign(socket, :saving, true)

    # Pipeline fields only — credentials and region belong to the assigned
    # Integrations connection (legacy aws_* settings stay untouched as the
    # fallback until an assignment happens).
    settings_to_update = %{
      "aws_sqs_queue_url" => aws_params["sqs_queue_url"] || "",
      "aws_sqs_dlq_url" => aws_params["sqs_dlq_url"] || "",
      "aws_sqs_queue_arn" => aws_params["sqs_queue_arn"] || "",
      "aws_sns_topic_arn" => aws_params["sns_topic_arn"] || "",
      "aws_ses_configuration_set" =>
        if(aws_params["ses_configuration_set"] in [nil, ""],
          do: "phoenixkit-tracking",
          else: aws_params["ses_configuration_set"]
        )
    }

    case Settings.update_settings_batch(settings_to_update) do
      {:ok, _results} ->
        new_aws_settings = build_aws_settings_map(aws_params)

        socket =
          socket
          |> assign(:aws_settings, new_aws_settings)
          |> assign(:saving, false)
          |> put_flash(:info, gettext("AWS settings saved successfully"))

        {:noreply, socket}

      {:error, _failed_operation, _failed_value, _changes} ->
        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, gettext("Failed to save AWS settings"))

        {:noreply, socket}
    end
  end

  def handle_event("assign_aws_integration", %{"uuid" => uuid}, socket) do
    # An empty uuid means "back to legacy" — clear the setting instead of
    # writing an empty value (the key isn't in Setting's optional-value
    # allowlist, so an empty-string write would fail changeset validation).
    # That allowlist is a core Setting concern, out of scope for this
    # package — the delete-vs-empty-string asymmetry with other settings
    # here is intentional, not an oversight, until core grows a way to add
    # a key to it from outside core itself.
    result =
      if uuid == "" do
        case Settings.delete_setting("emails_aws_integration_uuid") do
          {:error, :not_found} -> {:ok, nil}
          other -> other
        end
      else
        Settings.update_setting("emails_aws_integration_uuid", uuid)
      end

    case result do
      {:ok, _} ->
        # The next get_aws_*/0 call must see the newly selected connection
        # (or the legacy fallback) immediately, not after the credentials
        # cache's TTL — see Emails.invalidate_aws_credentials_cache/0.
        Emails.invalidate_aws_credentials_cache()

        socket =
          socket
          |> assign(:selected_aws_integration_uuid, uuid)
          |> put_flash(:info, gettext("SES credentials source updated"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update SES credentials source"))}
    end
  end

  defp mailer_config_snippet(%{config_app: app, config_module: mod}) do
    """
    config :#{app}, #{inspect(mod)},
      adapter: Swoosh.Adapters.AmazonSES,
      region: "eu-north-1"
    """
  end

  defp build_aws_settings_map(aws_params) do
    %{
      access_key_id: aws_params["access_key_id"] || "",
      secret_access_key: aws_params["secret_access_key"] || "",
      region: aws_params["region"] || "",
      sqs_queue_url: aws_params["sqs_queue_url"] || "",
      sqs_dlq_url: aws_params["sqs_dlq_url"] || "",
      sqs_queue_arn: aws_params["sqs_queue_arn"] || "",
      sns_topic_arn: aws_params["sns_topic_arn"] || "",
      ses_configuration_set: aws_params["ses_configuration_set"] || ""
    }
  end
end
