defmodule PhoenixKitEmails.Test.MigrationRepo do
  @moduledoc """
  A second connection to the SAME test database, with an ordinary pool instead
  of `Ecto.Adapters.SQL.Sandbox`.

  `Ecto.Migrator` runs each migration in a `Task` that checks out its own
  connection, which under a manual-mode sandbox has no owner and is refused.
  Rather than flipping the global sandbox mode (and perturbing every other test
  file that is running at the same time), the one test that needs a real
  migrator gets its own unsandboxed repo.

  Safe because the only migration run through it is this package's own chain:
  every statement is idempotent, and `down/1` rewrites a comment.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_emails,
    adapter: Ecto.Adapters.Postgres
end
