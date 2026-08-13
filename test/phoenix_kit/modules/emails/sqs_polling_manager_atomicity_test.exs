defmodule PhoenixKit.Modules.Emails.SQSPollingManagerAtomicityTest do
  @moduledoc """
  `enable_polling/0` writes three things — `email_ses_events`,
  `sqs_polling_enabled` and the first Oban job — and either all of them
  land or none do.

  Deliberately in its own file: every other `SQSPollingManager` test
  starts an Oban instance in its `setup`, and "no Oban is running" is
  precisely the third-step failure this file needs. The absence of that
  `start_supervised!` is the fixture.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingManager

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  test "a failed job insert leaves the SES-events flag exactly as it was" do
    {:ok, _} = Emails.set_ses_events(false)

    # Step three blows up (no Oban instance), so the transaction unwinds.
    # Before it existed, `set_ses_events(true)` had already been committed by
    # then: the click reported an error and silently flipped an eligibility
    # flag the operator never asked for.
    assert_raise RuntimeError, ~r/No Oban instance/, fn ->
      SQSPollingManager.enable_polling()
    end

    refute Emails.ses_events_enabled?()
    refute Emails.sqs_polling_enabled?()
  end

  test "and does not leave the polling toggle on either" do
    {:ok, _} = Emails.set_ses_events(true)
    refute Emails.sqs_polling_enabled?()

    assert_raise RuntimeError, ~r/No Oban instance/, fn ->
      SQSPollingManager.enable_polling()
    end

    # The flag that was already true stays true — a rollback restores the
    # prior state, it does not clear unrelated settings.
    assert Emails.ses_events_enabled?()
    refute Emails.sqs_polling_enabled?()
  end
end
