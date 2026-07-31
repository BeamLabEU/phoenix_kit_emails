defmodule PhoenixKit.Modules.Emails.BrevoPollingManagerTest do
  @moduledoc """
  Unit tests for `BrevoPollingManager`'s control surface — mirrors
  `SQSPollingManager`'s contract (enable/disable/poll_now/status), backed
  by an Oban instance in `testing: :manual` mode so `Oban.insert/1`
  persists a row without actually running the job.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp worker_jobs(states) do
    worker = BrevoPollingJob.worker_name()
    Repo.all(from(j in Oban.Job, where: j.worker == ^worker and j.state in ^states))
  end

  test "enable_polling/0 persists the setting and inserts the first job" do
    refute Emails.brevo_events_enabled?()

    assert {:ok, %Oban.Job{}} = BrevoPollingManager.enable_polling()
    assert Emails.brevo_events_enabled?()
  end

  test "disable_polling/0 clears the setting" do
    {:ok, _job} = BrevoPollingManager.enable_polling()
    assert :ok = BrevoPollingManager.disable_polling()
    refute Emails.brevo_events_enabled?()
  end

  test "set_polling_interval/1 rejects anything below 30000ms" do
    assert {:error, _} = BrevoPollingManager.set_polling_interval(29_999)
    assert Emails.get_brevo_polling_interval() == 120_000

    assert {:ok, _} = BrevoPollingManager.set_polling_interval(60_000)
    assert Emails.get_brevo_polling_interval() == 60_000
  end

  test "poll_now/0 inserts an immediate forced job even while polling is disabled" do
    refute Emails.brevo_events_enabled?()
    assert {:ok, %Oban.Job{} = job} = BrevoPollingManager.poll_now()

    # The `forced` flag is what makes this actually poll rather than
    # insert a job that no-ops on BrevoPollingJob's should_poll?/0 gate.
    assert job.args == %{"forced" => true}
  end

  test "enable_polling/0 while a next tick is already scheduled moves it to run now, not a duplicate" do
    {:ok, existing} = %{} |> BrevoPollingJob.new(schedule_in: 3_600) |> Oban.insert()
    assert existing.state == "scheduled"
    far_future = existing.scheduled_at

    assert {:ok, job} = BrevoPollingManager.enable_polling()

    assert job.id == existing.id
    assert DateTime.compare(job.scheduled_at, far_future) == :lt
    assert DateTime.diff(DateTime.utc_now(), job.scheduled_at, :second) |> abs() < 5

    assert [_single] = worker_jobs(["available", "scheduled"])
  end

  test "poll_now/0 called twice back to back inserts exactly one forced job" do
    assert {:ok, first} = BrevoPollingManager.poll_now()
    assert {:ok, second} = BrevoPollingManager.poll_now()

    assert first.id == second.id
    assert [_single] = worker_jobs(["available", "scheduled"])
  end

  test "poll_now/0 does not disturb an already-scheduled regular (non-forced) cycle" do
    {:ok, regular} = %{} |> BrevoPollingJob.new(schedule_in: 3_600) |> Oban.insert()
    assert regular.state == "scheduled"

    assert {:ok, forced} = BrevoPollingManager.poll_now()

    # Two distinct rows — different args (forced vs regular), so the
    # forced insert must never touch the regular chain's own next tick.
    assert forced.id != regular.id
    assert forced.args == %{"forced" => true}

    reloaded_regular = Repo.get!(Oban.Job, regular.id)
    assert reloaded_regular.state == "scheduled"
    assert DateTime.compare(reloaded_regular.scheduled_at, regular.scheduled_at) == :eq
  end

  test "status/0 reports the sender-aware profile count" do
    assert BrevoPollingManager.status().active_brevo_profiles == 0

    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    assert BrevoPollingManager.status().active_brevo_profiles == 1
  end

  test "status/0 defaults to polling every active account (empty exclusion list)" do
    assert Emails.get_brevo_polling_excluded_integrations() == []

    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    status = BrevoPollingManager.status()
    assert status.total_brevo_accounts == 1
    assert status.polling_brevo_accounts == 1
  end

  test "status/0 reflects an excluded account: N of M drops, M does not" do
    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    {:ok, _} = Emails.set_brevo_polling_excluded_integrations([integration_uuid])

    status = BrevoPollingManager.status()
    assert status.total_brevo_accounts == 1
    assert status.polling_brevo_accounts == 0
  end

  describe "integration_count/0" do
    test "0 with no active brevo_api integrations" do
      assert BrevoPollingManager.integration_count() == 0
    end

    test "counts distinct active integrations, not send profiles" do
      {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
      {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

      {:ok, _profile} =
        SendProfiles.create_send_profile(%{
          name: "Brevo test profile",
          integration_uuid: integration_uuid,
          provider_kind: "brevo_api",
          from_email: "sender@example.com"
        })

      assert BrevoPollingManager.integration_count() == 1
    end
  end

  describe "accounts/0 and toggle_account_polling/1" do
    setup do
      {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
      {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

      {:ok, _profile} =
        SendProfiles.create_send_profile(%{
          name: "Brevo test profile",
          integration_uuid: integration_uuid,
          provider_kind: "brevo_api",
          from_email: "sender@example.com"
        })

      %{integration_uuid: integration_uuid}
    end

    test "accounts/0 lists every active account as polled by default", %{
      integration_uuid: integration_uuid
    } do
      assert [{^integration_uuid, "Brevo test", true}] = BrevoPollingManager.accounts()
    end

    test "toggle_account_polling/1 excludes then re-includes an account", %{
      integration_uuid: integration_uuid
    } do
      assert {:ok, _} = BrevoPollingManager.toggle_account_polling(integration_uuid)
      assert [{^integration_uuid, "Brevo test", false}] = BrevoPollingManager.accounts()

      assert {:ok, _} = BrevoPollingManager.toggle_account_polling(integration_uuid)
      assert [{^integration_uuid, "Brevo test", true}] = BrevoPollingManager.accounts()
    end

    test "toggle_account_polling/1 ignores a uuid that isn't a currently-active integration" do
      stale_uuid = Ecto.UUID.generate()

      assert BrevoPollingManager.toggle_account_polling(stale_uuid) == {:ok, :ignored}
      assert Emails.get_brevo_polling_excluded_integrations() == []
    end
  end

  test "min_interval_ms/0 matches set_polling_interval/1's own floor" do
    assert BrevoPollingManager.min_interval_ms() == 30_000
    assert {:error, _} = BrevoPollingManager.set_polling_interval(29_999)
    assert {:ok, _} = BrevoPollingManager.set_polling_interval(30_000)
  end
end
