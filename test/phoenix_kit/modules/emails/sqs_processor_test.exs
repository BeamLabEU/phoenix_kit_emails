defmodule PhoenixKit.Modules.Emails.SQSProcessorTest do
  @moduledoc """
  Hard (Permanent) SES bounces auto-add the bounced recipient(s) to the rate
  limiter's blocklist; transient bounces must not (Stage E, E1).
  """

  # Not async: it writes settings rows. Each sandboxed test holds the rows it
  # wrote until it ends, and core's settings write (3.6: the row read under
  # a lock, then the value and its history) makes two async tests that write
  # the same keys in another order deadlock.
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.SQSProcessor

  setup do
    # find_email_log_by_message_id/1 routes through Emails.get_log_by_message_id/1,
    # which no-ops with {:error, :system_disabled} unless the emails system is on.
    Emails.enable_system()
    :ok
  end

  defp unique_message_id, do: "msg-#{System.unique_integer([:positive, :monotonic])}"

  defp bounce_event(bounce_type, recipients, message_id) do
    %{
      "eventType" => "Bounce",
      "mail" => %{
        "messageId" => message_id,
        "destination" => Enum.map(recipients, & &1["emailAddress"]),
        "source" => "sender@example.com",
        "commonHeaders" => %{"subject" => "Test"},
        "timestamp" => "2026-07-12T10:00:00.000Z"
      },
      "bounce" => %{
        "bounceType" => bounce_type,
        "bounceSubType" => "General",
        "bouncedRecipients" => recipients,
        "timestamp" => "2026-07-12T10:00:00.000Z"
      }
    }
  end

  defp complaint_event(recipients, message_id, feedback_type \\ "abuse") do
    %{
      "eventType" => "Complaint",
      "mail" => %{
        "messageId" => message_id,
        "destination" => Enum.map(recipients, & &1["emailAddress"]),
        "source" => "sender@example.com",
        "commonHeaders" => %{"subject" => "Test"},
        "timestamp" => "2026-07-12T10:00:00.000Z"
      },
      "complaint" => %{
        "complainedRecipients" => recipients,
        "complaintFeedbackType" => feedback_type,
        "timestamp" => "2026-07-12T10:00:00.000Z"
      }
    }
  end

  defp create_log_for(message_id, to_email) do
    {:ok, log} =
      Log.create_log(%{
        message_id: message_id,
        to: to_email,
        from: "sender@example.com",
        provider: "aws_ses",
        status: "sent"
      })

    log
  end

  describe "process_email_event/1 — bounce" do
    test "a Permanent bounce adds every bounced recipient to the blocklist as hard_bounce" do
      message_id = unique_message_id()

      recipients = [
        %{
          "emailAddress" => "bounced1@example.com",
          "status" => "5.1.1",
          "diagnosticCode" => "smtp; 550 5.1.1 unknown user"
        },
        %{
          "emailAddress" => "bounced2@example.com",
          "status" => "5.1.1",
          "diagnosticCode" => "smtp; 550 5.1.1 unknown user"
        }
      ]

      create_log_for(message_id, "bounced1@example.com")

      assert {:ok, _} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      assert RateLimiter.is_blocked?("bounced1@example.com")
      assert RateLimiter.is_blocked?("bounced2@example.com")

      assert [%{reason: "hard_bounce"}] =
               RateLimiter.list_blocklist(%{search: "bounced1@example.com"})
    end

    test "a Transient bounce does not add the recipient to the blocklist" do
      message_id = unique_message_id()

      recipients = [
        %{
          "emailAddress" => "softbounce@example.com",
          "status" => "4.2.2",
          "diagnosticCode" => "smtp; 450 4.2.2 mailbox full"
        }
      ]

      create_log_for(message_id, "softbounce@example.com")

      assert {:ok, _} =
               SQSProcessor.process_email_event(bounce_event("Transient", recipients, message_id))

      refute RateLimiter.is_blocked?("softbounce@example.com")
    end

    test "a Permanent bounce blocklists the recipient even when no matching email log exists" do
      message_id = unique_message_id()
      recipients = [%{"emailAddress" => "orphan-bounce@example.com", "status" => "5.1.1"}]

      assert {:error, :email_log_not_found} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      assert RateLimiter.is_blocked?("orphan-bounce@example.com")
    end

    test "a malformed recipient address is rejected by the blocklist changeset (not blocklisted), and bounce event processing still succeeds" do
      # `EmailBlocklist.changeset/2` validates :email format, so this hits
      # `blocklist_recipient/1`'s graceful `{:error, reason} -> Logger.error(...)`
      # branch, not the `rescue` clause — see the next test for that one.
      # Previously this test asserted only the unrelated
      # :email_log_not_found outcome and never checked what actually
      # happened to the blocklist attempt, so it would have kept "passing"
      # even if this recipient had silently been blocklisted.
      message_id = unique_message_id()
      recipients = [%{"emailAddress" => "not-an-email", "status" => "5.1.1"}]

      assert {:error, :email_log_not_found} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      refute RateLimiter.is_blocked?("not-an-email")
    end

    test "an exception while blocklisting a recipient does not break bounce event processing" do
      # Genuinely exercises blocklist_recipient/1's `rescue` clause (as
      # opposed to the graceful `{:error, reason}` branch the previous test
      # covers): the email column is VARCHAR(255) with no changeset
      # validate_length, so a value past that satisfies validate_format but
      # still overflows the column — Postgrex raises rather than returning
      # a changeset error, since there's no unique_constraint/check_constraint
      # mapping for this failure mode.
      message_id = unique_message_id()
      oversized_email = String.duplicate("a", 300) <> "@example.com"
      recipients = [%{"emailAddress" => oversized_email, "status" => "5.1.1"}]

      assert {:error, :email_log_not_found} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      refute RateLimiter.is_blocked?(oversized_email)
    end
  end

  describe "process_email_event/1 — complaint" do
    test "a spam complaint adds the complaining recipient to the blocklist as complaint" do
      message_id = unique_message_id()
      create_log_for(message_id, "complainer@example.com")

      event = complaint_event([%{"emailAddress" => "Complainer@example.com"}], message_id)

      assert {:ok, _} = SQSProcessor.process_email_event(event)

      assert RateLimiter.is_blocked?("complainer@example.com")

      assert [%{reason: "complaint"}] =
               RateLimiter.list_blocklist(%{search: "complainer@example.com"})
    end

    test "a complaint blocklists the recipient even when no matching email log exists" do
      event =
        complaint_event(
          [%{"emailAddress" => "orphan-complaint@example.com"}],
          unique_message_id()
        )

      SQSProcessor.process_email_event(event)

      assert RateLimiter.is_blocked?("orphan-complaint@example.com")
    end

    test "a not-spam report does not blocklist the recipient" do
      message_id = unique_message_id()
      create_log_for(message_id, "notspam@example.com")

      event =
        complaint_event([%{"emailAddress" => "notspam@example.com"}], message_id, "not-spam")

      SQSProcessor.process_email_event(event)

      refute RateLimiter.is_blocked?("notspam@example.com")
    end
  end

  describe "process_email_event/1 — replayed events" do
    test "a replayed complaint does not put back an address removed from the blocklist" do
      message_id = unique_message_id()
      create_log_for(message_id, "replayed-complaint@example.com")
      event = complaint_event([%{"emailAddress" => "replayed-complaint@example.com"}], message_id)

      assert {:ok, _} = SQSProcessor.process_email_event(event)
      assert RateLimiter.is_blocked?("replayed-complaint@example.com")

      RateLimiter.remove_from_blocklist("replayed-complaint@example.com")

      assert {:ok, _} = SQSProcessor.process_email_event(event)
      refute RateLimiter.is_blocked?("replayed-complaint@example.com")
    end

    test "a replayed hard bounce does not put back an address removed from the blocklist" do
      message_id = unique_message_id()
      create_log_for(message_id, "replayed-bounce@example.com")

      event =
        bounce_event(
          "Permanent",
          [%{"emailAddress" => "replayed-bounce@example.com"}],
          message_id
        )

      assert {:ok, _} = SQSProcessor.process_email_event(event)
      assert RateLimiter.is_blocked?("replayed-bounce@example.com")

      RateLimiter.remove_from_blocklist("replayed-bounce@example.com")

      assert {:ok, _} = SQSProcessor.process_email_event(event)
      refute RateLimiter.is_blocked?("replayed-bounce@example.com")
    end

    test "a first complaint still blocks when another event type is already recorded" do
      message_id = unique_message_id()
      create_log_for(message_id, "bounce-then-complaint@example.com")
      recipients = [%{"emailAddress" => "bounce-then-complaint@example.com"}]

      assert {:ok, _} =
               SQSProcessor.process_email_event(bounce_event("Transient", recipients, message_id))

      refute RateLimiter.is_blocked?("bounce-then-complaint@example.com")

      assert {:ok, _} = SQSProcessor.process_email_event(complaint_event(recipients, message_id))
      assert RateLimiter.is_blocked?("bounce-then-complaint@example.com")
    end
  end

  describe "Emails.process_webhook_event/1 — the SNS webhook path" do
    setup do
      Emails.set_ses_events(true)
      :ok
    end

    test "a hard bounce blocklists the recipient" do
      message_id = unique_message_id()
      create_log_for(message_id, "webhook-bounce@example.com")

      event =
        bounce_event("Permanent", [%{"emailAddress" => "webhook-bounce@example.com"}], message_id)

      # SES publishes the type capitalized ("Bounce"); it is recorded as "bounce".
      assert {:ok, %{event_type: "bounce", bounce_type: "hard"}} =
               Emails.process_webhook_event(event)

      assert [%{reason: "hard_bounce"}] =
               RateLimiter.list_blocklist(%{search: "webhook-bounce@example.com"})
    end

    test "a complaint blocklists the recipient, even without a matching log" do
      event =
        complaint_event(
          [%{"emailAddress" => "webhook-complaint@example.com"}],
          unique_message_id()
        )

      assert {:error, :email_log_not_found} = Emails.process_webhook_event(event)

      assert [%{reason: "complaint"}] =
               RateLimiter.list_blocklist(%{search: "webhook-complaint@example.com"})
    end

    test "a transient bounce and a not-spam report do not blocklist" do
      recipients = [%{"emailAddress" => "webhook-clean@example.com"}]

      Emails.process_webhook_event(bounce_event("Transient", recipients, unique_message_id()))

      Emails.process_webhook_event(complaint_event(recipients, unique_message_id(), "not-spam"))

      refute RateLimiter.is_blocked?("webhook-clean@example.com")
    end

    test "nothing is blocklisted while SES events are off" do
      Emails.set_ses_events(false)

      event =
        complaint_event([%{"emailAddress" => "webhook-off@example.com"}], unique_message_id())

      assert {:ok, :skipped} = Emails.process_webhook_event(event)
      refute RateLimiter.is_blocked?("webhook-off@example.com")
    end
  end

  describe "process_email_event/1 — lookups that find nothing to update" do
    test "with the module off the event is skipped, not crashed on, and nothing is blocklisted" do
      Emails.disable_system()

      recipients = [%{"emailAddress" => "module-off@example.com"}]

      for event <- [
            complaint_event(recipients, unique_message_id()),
            bounce_event("Permanent", recipients, unique_message_id())
          ] do
        assert {:error, :system_disabled} = SQSProcessor.process_email_event(event)
      end

      refute RateLimiter.is_blocked?("module-off@example.com")
    end

    test "an event without a message id returns an error instead of raising" do
      event =
        [%{"emailAddress" => "no-id@example.com"}]
        |> complaint_event(unique_message_id())
        |> put_in(["mail", "messageId"], nil)

      assert {:error, :invalid_message_id} = SQSProcessor.process_email_event(event)
    end
  end
end
