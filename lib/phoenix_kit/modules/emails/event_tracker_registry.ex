defmodule PhoenixKit.Modules.Emails.EventTrackerRegistry do
  @moduledoc """
  Emails-local registry of `EventTracker` implementations — decision §9.2
  (option B) of the universalization spec: trackers all live in
  `phoenix_kit_emails` today (Mailgun would too), so a compile-time list
  here is simpler than a core module-registry callback for a cross-module
  need that doesn't exist yet. Revisit only if a tracker must ship from a
  different package.

  Adding a provider (e.g. Mailgun) is: implement `EventTracker`, add the
  module here. `EventTrackerReconciler` and the admin panel (the
  "Delivery event tracking" settings section) pick it up automatically —
  no other wiring.

  ## The admin panel also expects a duck-typed "Manager API"

  A registered tracker module today is also its own Manager
  (`SQSPollingManager`, `BrevoPollingManager`) — the admin panel calls a
  few more functions on it that are **not** part of the formal
  `EventTracker` behaviour (spec §3's "Manager API shared shape" was
  always informal, this just extends that same convention):

  - `enable_polling/0`, `disable_polling/0` — the Tracking toggle.
  - `poll_now/0` — the Poll now action (forced one-off cycle, still
    respects `Emails.enabled?/0`).
  - `set_polling_interval/1` — the per-tracker interval editor.
  - `integration_count/0` — the Integration column's count (required).
  - `accounts/0` / `toggle_account_polling/1` — the Accounts column's
    per-integration opt-out. **Optional**: only define these if the
    provider has a real multi-account opt-out concept (Brevo does; SES
    doesn't). The panel checks `function_exported?/3` before calling
    either — a tracker without them simply renders no Accounts cell.
  """

  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.SQSPollingManager

  @trackers [SQSPollingManager, BrevoPollingManager]

  @doc "Every registered `EventTracker` module."
  @spec trackers() :: [module()]
  def trackers, do: @trackers
end
