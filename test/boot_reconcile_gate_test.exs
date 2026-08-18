defmodule PhoenixKit.Modules.Emails.BootReconcileGateTest do
  @moduledoc """
  The email supervisor spawns a boot Task that reconciles event trackers. The
  reconcile writes — it calls `Oban.cancel_all_jobs/2` — from that Task, which
  owns no Ecto sandbox connection. Under a host's test suite the write can only
  fail, and it fails loudly: a DBConnection.OwnershipError dump in every run of
  every host that installs this module.

  Nothing is lost by skipping it there: in a testing mode Oban does not execute
  the chains the reconcile would seed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Supervisor, as: EmailSupervisor

  test "boot reconcile runs when Oban is live" do
    assert EmailSupervisor.reconcile_on_boot?(%Oban.Config{testing: :disabled, repo: nil})
  end

  test "boot reconcile is skipped in every Oban testing mode" do
    for mode <- [:manual, :inline] do
      refute EmailSupervisor.reconcile_on_boot?(%Oban.Config{testing: mode, repo: nil}),
             "expected boot reconcile to be skipped with testing: #{mode}"
    end
  end
end
