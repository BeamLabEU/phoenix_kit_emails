defmodule PhoenixKit.Modules.Emails.EventTrackerRegistry do
  @moduledoc """
  Emails-local registry of `EventTracker` implementations — decision §9.2
  (option B) of the universalization spec: trackers all live in
  `phoenix_kit_emails` today (Mailgun would too), so a compile-time list
  here is simpler than a core module-registry callback for a cross-module
  need that doesn't exist yet. Revisit only if a tracker must ship from a
  different package.

  Adding a provider (e.g. Mailgun) is: implement `EventTracker`, add the
  module here. `EventTrackerReconciler` and (eventually) the admin panel
  pick it up automatically — no other wiring.
  """

  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.SQSPollingManager

  @trackers [SQSPollingManager, BrevoPollingManager]

  @doc "Every registered `EventTracker` module."
  @spec trackers() :: [module()]
  def trackers, do: @trackers
end
