defmodule PhoenixKit.Modules.Emails.EventTrackerTest do
  @moduledoc """
  Behaviour conformance (spec §8): every REGISTERED tracker implements
  the full `EventTracker` callback set, and `should_run?/1` is exactly
  `eligible?/0 and enabled?/0` — not some other combination.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.EventTracker
  alias PhoenixKit.Modules.Emails.EventTrackerRegistry

  describe "every registered tracker implements EventTracker" do
    for tracker <- EventTrackerRegistry.trackers() do
      test "#{inspect(tracker)} exports every EventTracker callback" do
        tracker = unquote(tracker)

        declared_behaviours =
          tracker.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert EventTracker in declared_behaviours

        for {fun, arity} <- [
              provider_kind: 0,
              label: 0,
              eligible?: 0,
              enabled?: 0,
              poll_cycle: 1,
              interval_ms: 0,
              min_interval_ms: 0,
              worker: 0
            ] do
          assert function_exported?(tracker, fun, arity),
                 "#{inspect(tracker)} does not export #{fun}/#{arity}"
        end
      end

      test "#{inspect(tracker)}: provider_kind/0, label/0, and worker/0 return sane shapes" do
        tracker = unquote(tracker)

        assert is_binary(tracker.provider_kind())
        assert tracker.provider_kind() != ""
        assert is_binary(tracker.label())
        assert tracker.label() != ""
        assert is_atom(tracker.worker())
        assert Code.ensure_loaded?(tracker.worker())
        assert function_exported?(tracker.worker(), :perform, 1)
      end

      test "#{inspect(tracker)}: min_interval_ms/0 is a positive integer" do
        tracker = unquote(tracker)

        assert is_integer(tracker.min_interval_ms())
        assert tracker.min_interval_ms() > 0
      end

      test "#{inspect(tracker)}: settings_component/1 answers a loadable component or nil" do
        tracker = unquote(tracker)

        case EventTracker.settings_component(tracker) do
          nil ->
            :ok

          component ->
            assert Code.ensure_loaded?(component)
            # The panel renders it with nothing but an id — anything else it
            # needs, it has to load in update/2 itself.
            assert function_exported?(component, :update, 2)
        end
      end
    end
  end

  describe "settings_component/1" do
    alias PhoenixKit.Modules.Emails.FakeEventTracker

    test "a tracker that never heard of the callback gets nil, not a crash" do
      refute function_exported?(FakeEventTracker, :settings_component, 0)
      assert EventTracker.settings_component(FakeEventTracker) == nil
    end
  end

  describe "should_run?/1" do
    setup do
      on_exit(fn ->
        Application.delete_env(:phoenix_kit_emails, :fake_tracker_eligible)
        Application.delete_env(:phoenix_kit_emails, :fake_tracker_enabled)
      end)
    end

    alias PhoenixKit.Modules.Emails.FakeEventTracker

    test "true only when both eligible? and enabled? are true" do
      Application.put_env(:phoenix_kit_emails, :fake_tracker_eligible, true)
      Application.put_env(:phoenix_kit_emails, :fake_tracker_enabled, true)
      assert EventTracker.should_run?(FakeEventTracker)
    end

    test "false when eligible? is false, even if enabled? is true" do
      Application.put_env(:phoenix_kit_emails, :fake_tracker_eligible, false)
      Application.put_env(:phoenix_kit_emails, :fake_tracker_enabled, true)
      refute EventTracker.should_run?(FakeEventTracker)
    end

    test "false when enabled? is false, even if eligible? is true" do
      Application.put_env(:phoenix_kit_emails, :fake_tracker_eligible, true)
      Application.put_env(:phoenix_kit_emails, :fake_tracker_enabled, false)
      refute EventTracker.should_run?(FakeEventTracker)
    end

    test "false when neither is true" do
      refute EventTracker.should_run?(FakeEventTracker)
    end
  end

  test "the registry lists at least SES and Brevo" do
    trackers = EventTrackerRegistry.trackers()

    assert PhoenixKit.Modules.Emails.SQSPollingManager in trackers
    assert PhoenixKit.Modules.Emails.BrevoPollingManager in trackers
  end
end
