defmodule PhoenixKit.Modules.Emails.Supervisor do
  @moduledoc """
  Supervisor for PhoenixKit email tracking system.

  This module manages all processes necessary for email tracking:
  - Kicks off Oban-based SQS and Brevo polling at boot, symmetrically (see
    `SQSPollingManager`/`BrevoPollingManager`) — each starts iff its own
    eligibility+enabled gate is satisfied
  - Registers the unified email provider
  - Additional processes (metrics, archiving, etc.)

  ## Integration into Parent Application

  Add supervisor to your application's supervision tree:

      # In lib/your_app/application.ex
      def start(_type, _args) do
        children = [
          # ... your other processes

          # PhoenixKit Email Tracking
          PhoenixKit.Modules.Emails.Supervisor
        ]

        opts = [strategy: :one_for_one, name: YourApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

  ## Configuration

  Supervisor automatically reads settings from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable SQS Worker
  - `sqs_polling_interval_ms` - polling interval
  - other SQS settings

  ## Process Management

  SQS polling is driven entirely by Oban (see `SQSPollingManager`) and can be
  toggled at runtime without an application restart:

      # Stop polling
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()

      # Start polling
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

      # Check status
      PhoenixKit.Modules.Emails.SQSPollingManager.status()

  ## Monitoring

  Supervisor provides information about process state:

      # Get list of child processes
      Supervisor.which_children(PhoenixKit.Modules.Emails.Supervisor)

      # Get process count
      Supervisor.count_children(PhoenixKit.Modules.Emails.Supervisor)
  """

  use Supervisor

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoIntegrations
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.SQSPollingManager

  @doc """
  Starts supervisor for email tracking system.

  ## Options

  - `:name` - supervisor process name (defaults to `__MODULE__`)

  ## Examples

      {:ok, pid} = PhoenixKit.Modules.Emails.Supervisor.start_link()
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def init(_opts) do
    # Register unified email provider before starting children
    alias PhoenixKit.Modules.Emails.ApplicationIntegration
    ApplicationIntegration.register()

    # SQS polling runs as Oban jobs (see build_oban_starter/0 + SQSPollingManager),
    # so the supervisor itself has no long-running polling child of its own.
    #
    # Emails.aws_ses_credentials/0's cache — relies on `PhoenixKit.Cache.Registry`
    # already being started, which core's own `PhoenixKit.Supervisor` starts
    # before any module's children (see core's build_children/1). Missing in
    # a standalone context (e.g. this package's own test suite, which never
    # boots core's supervision tree at all) is fine: `PhoenixKit.Cache.get/put`
    # already no-op gracefully when their target instance isn't registered.
    children = [
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :emails_aws_credentials, ttl: 60_000},
        id: :emails_aws_credentials_cache
      )
      | build_oban_starter()
    ]

    # Use :one_for_one strategy - if one process crashes,
    # only that one is restarted
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns information about email tracking system status.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Supervisor.system_status()
      %{
        supervisor_running: true,
        polling_status: %{enabled: true, pending_jobs: 1, ...},
        children_count: 0
      }
  """
  def system_status(supervisor \\ __MODULE__) do
    child_count = Supervisor.count_children(supervisor)

    polling_status =
      try do
        SQSPollingManager.status()
      catch
        _, _ -> %{error: "polling_status_unavailable"}
      end

    %{
      supervisor_running: true,
      polling_status: polling_status,
      children_count: child_count.active
    }
  catch
    _, _ ->
      %{
        supervisor_running: false,
        error: "supervisor_not_accessible"
      }
  end

  ## --- Helper Functions for Integration ---

  @doc """
  Returns child spec for integration into parent supervisor.

  This function is used when you want more precise control
  over email tracking integration in your application.

  ## Examples

      # In lib/your_app/application.ex
      def start(_type, _args) do
        children = [
          # ... other processes
          PhoenixKit.Modules.Emails.Supervisor.child_spec([])
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  ## --- Private Functions ---

  # Checks for minimum SQS configuration
  defp has_sqs_configuration? do
    sqs_config = Emails.get_sqs_config()

    not is_nil(sqs_config.queue_url) and
      sqs_config.queue_url != ""
  end

  # Build a one-off supervised Task that waits for Oban, then starts whichever
  # poller(s) are eligible+enabled. One shared Task (not one per provider) —
  # both gates are checked after the same single wait_for_oban/2, so there's
  # no reason to pay the polling-loop cost twice.
  defp build_oban_starter do
    if should_start_oban_polling?() or should_start_brevo_oban_polling?() do
      [
        {Task, fn -> start_oban_polling_when_ready() end}
      ]
    else
      []
    end
  end

  defp start_oban_polling_when_ready do
    case wait_for_oban(10, 500) do
      :ok ->
        maybe_start_sqs_polling()
        maybe_start_brevo_polling()

      :timeout ->
        Logger.warning(
          "Email Supervisor: Oban not available after timeout, skipping polling jobs"
        )
    end
  end

  defp maybe_start_sqs_polling do
    if should_start_oban_polling?() do
      Logger.info("Email Supervisor: Starting initial SQS polling job via Oban")

      case SQSPollingManager.enable_polling() do
        {:ok, job} ->
          Logger.info("Email Supervisor: Initial SQS polling started", %{job: inspect(job)})

        {:error, reason} ->
          Logger.warning("Email Supervisor: Failed to start initial SQS polling job", %{
            reason: inspect(reason)
          })
      end
    end
  end

  # Symmetric to maybe_start_sqs_polling/0 — Brevo was previously started
  # ONLY by the settings-UI toggle (web/settings_sections/brevo_events.ex),
  # never at boot. On a fresh database, or if the self-scheduling job is
  # ever lost (prune, cancel, crash), Brevo polling silently stayed off
  # until a human re-toggled it. See dev_docs/specs/
  # 2026-07-26-email-event-tracking-universalization-spec.md §1.1.
  defp maybe_start_brevo_polling do
    if should_start_brevo_oban_polling?() do
      Logger.info("Email Supervisor: Starting initial Brevo polling job via Oban")

      case BrevoPollingManager.enable_polling() do
        {:ok, job} ->
          Logger.info("Email Supervisor: Initial Brevo polling started", %{job: inspect(job)})

        {:error, reason} ->
          Logger.warning("Email Supervisor: Failed to start initial Brevo polling job", %{
            reason: inspect(reason)
          })
      end
    end
  end

  defp wait_for_oban(0, _delay), do: :timeout

  defp wait_for_oban(attempts, delay) do
    case Oban.Registry.config(Oban) do
      %Oban.Config{} -> :ok
    end
  catch
    _, _ ->
      Process.sleep(delay)
      wait_for_oban(attempts - 1, delay)
  end

  @doc false
  # Not `defp` so the boot gate is unit-testable directly, without needing
  # to spawn the supervisor's Task and race its async enable_polling/0 call
  # — same rationale as SQSPollingJob.should_poll?/0 et al.
  def should_start_oban_polling? do
    Emails.enabled?() &&
      Emails.ses_events_enabled?() &&
      Emails.sqs_polling_enabled?() &&
      has_sqs_configuration?()
  end

  @doc false
  # Brevo has no separate feature/eligibility key (unlike SES's
  # email_ses_events) — an active brevo_api integration IS eligibility, per
  # BrevoPollingJob.active_brevo_integrations/0's own gate. Per-integration
  # opt-out (brevo_polling_excluded_integrations) is deliberately NOT
  # applied here: this is a coarse "does a matching event source exist at
  # all" boot gate, not the per-cycle filter — if every integration happens
  # to be opted out, the chain still boots and each cycle is a cheap no-op,
  # same tolerance the pre-existing per-cycle gate already has. Not `defp`
  # — same testability rationale as should_start_oban_polling?/0 above.
  def should_start_brevo_oban_polling? do
    Emails.enabled?() &&
      Emails.brevo_events_enabled?() &&
      BrevoIntegrations.active_integration_uuids() != []
  end
end
