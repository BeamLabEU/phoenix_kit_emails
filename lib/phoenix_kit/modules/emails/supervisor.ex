defmodule PhoenixKit.Modules.Emails.Supervisor do
  @moduledoc """
  Supervisor for PhoenixKit email tracking system.

  This module manages all processes necessary for email tracking:
  - Bootstraps every registered `EventTracker` (SES, Brevo, …) at boot via
    `EventTrackerReconciler.reconcile/0` — a tracker's chain starts iff
    its own `eligible?/0 and enabled?/0` gate is satisfied. Boot reconcile
    is latency polish (spec §4.3): it makes an eligible tracker start
    immediately instead of waiting for the periodic reconcile Cron
    (`EventTrackerReconcileWorker`), which is the actual correctness
    backbone.
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

  - `sqs_polling_enabled` / SES events / queue URL — SQS chain boot gate
  - `brevo_events_enabled` — Brevo chain boot gate
  - `email_enabled` — system switch (both chains)
  - polling intervals and other provider settings

  ## Process Management

  Both pollers are driven entirely by Oban and can be toggled at runtime
  without an application restart:

      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      PhoenixKit.Modules.Emails.BrevoPollingManager.enable_polling()
      PhoenixKit.Modules.Emails.BrevoPollingManager.disable_polling()

  Boot re-inserts each enabled chain via `enable_polling/0` so a dead
  chain (no queued job after a crash or bad deploy) self-heals when the
  setting is still on. If a next tick is already scheduled, the managers'
  unique/replace insert moves it to run now rather than appending a
  second row.

  ## Monitoring

  Supervisor provides information about process state:

      # Get list of child processes
      Supervisor.which_children(PhoenixKit.Modules.Emails.Supervisor)

      # Get process count
      Supervisor.count_children(PhoenixKit.Modules.Emails.Supervisor)
  """

  use Supervisor

  require Logger

  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
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

    # Polling runs as Oban jobs (see build_oban_starter/0 + the managers),
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
        brevo_polling_status: %{enabled: true, pending_jobs: 1, ...},
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

    brevo_polling_status =
      try do
        BrevoPollingManager.status()
      catch
        _, _ -> %{error: "polling_status_unavailable"}
      end

    %{
      supervisor_running: true,
      polling_status: polling_status,
      brevo_polling_status: brevo_polling_status,
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

  ## --- Boot gates (public @doc false for unit tests) ---
  #
  # Kept as named predicates because they read well at a call site and their
  # own test covers them, but they are NOT a second definition of the gate:
  # boot goes through `EventTrackerReconciler.reconcile/0`, which starts a
  # tracker's chain iff `EventTracker.should_run?/1`. Delegating means they
  # cannot drift from what boot actually does — the earlier hand-written
  # copies had already drifted (SQS's omitted the sender-aware gate; Brevo's
  # omitted the active-integration requirement).

  @doc false
  # Whether boot re-seeds the SQS self-scheduling chain: the system switch,
  # SES events, a queue URL and an actively-configured sender (all
  # `eligible?/0`), plus the sqs_polling toggle (`enabled?/0`).
  def should_start_sqs_polling?, do: EventTracker.should_run?(SQSPollingManager)

  @doc false
  # Whether boot re-seeds the Brevo self-scheduling chain: the system switch
  # and at least one active Brevo integration (`eligible?/0`), plus the
  # brevo_events toggle (`enabled?/0`). A toggle with no integration behind
  # it deliberately does NOT seed a chain — the reconcile Cron picks the
  # tracker up within one tick of an integration appearing, so nothing needs
  # a manual re-toggle either way.
  def should_start_brevo_polling?, do: EventTracker.should_run?(BrevoPollingManager)

  ## --- Private Functions ---

  # Always spawns the Task — reconcile must run unconditionally, since it
  # is the mechanism that decides which trackers to start (and the only
  # boot-time signal for it is "is Oban ready yet", not any single
  # tracker's own eligibility). Previously (P0, task #56) this was gated
  # on a pair of provider-specific booleans and called each manager's
  # enable_polling/0 directly; superseded here by
  # EventTrackerReconciler.reconcile/0, which generalizes the same fix
  # (spec §1.1 — Brevo bootstrapped identically to SES) to every
  # registered tracker instead of two hand-wired ones. See spec §4.3
  # "Boot reconcile".
  defp build_oban_starter do
    [
      {Task, fn -> start_polling_when_oban_ready() end}
    ]
  end

  defp start_polling_when_oban_ready do
    case wait_for_oban(10, 500) do
      :ok ->
        Logger.info("Email Supervisor: Reconciling event trackers")

        results = EventTrackerReconciler.reconcile()
        Logger.info("Email Supervisor: Event tracker reconcile complete", %{results: results})

      :timeout ->
        Logger.warning(
          "Email Supervisor: Oban not available after timeout, skipping tracker reconcile"
        )
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
end
