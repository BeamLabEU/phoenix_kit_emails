defmodule PhoenixKit.Modules.Emails.SupervisorBootTest do
  @moduledoc """
  Boot wiring (spec §1.1, §4.3 "Boot reconcile"): `Emails.Supervisor`
  always spawns exactly one Task that, once Oban is ready, calls
  `EventTrackerReconciler.reconcile/0` for every registered tracker —
  replacing the old pair of provider-specific boot gates (task #56 P0)
  that could only ever cover the two hand-wired providers. This is a
  static shape test (`init/1`'s children), not a live-reconcile test —
  see `EventTrackerReconcilerTest` for the actual reconcile behavior the
  Task's body triggers.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Supervisor, as: EmailsSupervisor

  test "init/1 always includes exactly one boot Task, regardless of tracker state" do
    {:ok, {_flags, children}} = EmailsSupervisor.init([])

    assert Enum.count(children, &task_child?/1) == 1
  end

  test "init/1 also includes the AWS credentials cache child" do
    {:ok, {_flags, children}} = EmailsSupervisor.init([])

    assert Enum.any?(children, &cache_child?/1)
  end

  defp task_child?(%{start: {Task, :start_link, _}}), do: true
  defp task_child?(_), do: false

  defp cache_child?(%{id: :emails_aws_credentials_cache}), do: true
  defp cache_child?(_), do: false
end
