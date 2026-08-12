defmodule PhoenixKit.Modules.Emails.AwsIntegrations do
  @moduledoc """
  Shared "which AWS SES account(s) are actually active" resolution, used by
  everything that needs to reach AWS on behalf of the currently-configured
  sender(s): `SQSPollingJob` (the background poll), the per-account tracking
  settings in the "Amazon SES & SQS" section, and the "Delivery Event
  Tracking" panel's per-account opt-out list.

  "Active" means an *enabled* `PhoenixKit.Email.SendProfile` pointed at an
  `"aws_ses"` integration — the same sender-aware definition
  `BrevoIntegrations` uses for Brevo, and the multi-account counterpart of
  the single `emails_aws_integration_uuid` setting the legacy path still
  reads (see `PhoenixKit.Modules.Emails.get_aws_access_key/0`).

  Deliberately a mirror of `BrevoIntegrations` rather than a shared generic:
  the credential SHAPE differs (Brevo has one `api_key`, SES needs
  access/secret/region as a triple), and the two providers' notions of
  "reachable" have already drifted once. Keeping them parallel-but-separate
  is what lets each grow its own gate without a conditional in the middle.
  """

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails

  @doc """
  Every distinct `integration_uuid` referenced by an enabled `aws_ses`
  SendProfile. Multiple profiles can share one integration/AWS account —
  deduplicated so callers don't poll the same queue twice per cycle.

  ## Examples

      iex> PhoenixKit.Modules.Emails.AwsIntegrations.active_integration_uuids()
      ["019fb9ec-0000-7000-8000-000000000000"]
  """
  @spec active_integration_uuids() :: [String.t()]
  def active_integration_uuids do
    SendProfiles.list_send_profiles()
    |> Enum.filter(&active_ses_profile?/1)
    |> Enum.map(& &1.integration_uuid)
    |> Enum.uniq()
  end

  defp active_ses_profile?(%SendProfile{
         enabled: true,
         provider_kind: "aws_ses",
         integration_uuid: uuid
       }),
       do: is_binary(uuid) and uuid != ""

  defp active_ses_profile?(_profile), do: false

  @doc """
  Resolves the decrypted AWS credentials for one `aws_ses` integration as
  `%{access_key: ..., secret_key: ..., region: ...}`.

  The region falls back to the connection-less default (`"us-east-1"`, the
  same floor `migrate_legacy/0` writes) when the connection was saved
  without one: an SQS queue URL already carries its own region in the host
  name, and ExAws only needs a syntactically valid region to sign with. A
  MISSING key or secret, by contrast, is a hard `{:error, :missing_credentials}`
  — signing with a blank key would fail per-request, once per poll cycle,
  with an opaque AWS error instead of one clear log line here.

  ## Examples

      iex> PhoenixKit.Modules.Emails.AwsIntegrations.resolve_credentials("uuid")
      {:ok, %{access_key: "AKIA...", secret_key: "...", region: "eu-north-1"}}
  """
  @spec resolve_credentials(String.t()) ::
          {:ok, %{access_key: String.t(), secret_key: String.t(), region: String.t()}}
          | {:error, term()}
  def resolve_credentials(integration_uuid) when is_binary(integration_uuid) do
    # Reads through `Emails.aws_ses_credentials/1`'s per-account TTL cache
    # rather than `Integrations.get_credentials/1` directly: the poller
    # resolves every active account once per cycle, and each uncached
    # resolution is a DB read plus a decrypt.
    #
    # Staleness is bounded by that TTL (60s) and nothing more. Editing a
    # connection's credentials happens on CORE's Integrations page, which has
    # no hook into this package, so there is no write site here to invalidate
    # from — `Emails.invalidate_aws_credentials_cache/0` covers the changes
    # this package itself makes, and the TTL covers the rest. A poller that
    # keeps using an old key for up to a minute retries on the next cycle;
    # this is why the cache has a TTL at all rather than living forever.
    creds = Emails.aws_ses_credentials(integration_uuid)

    access_key = present(creds["access_key"])
    secret_key = present(creds["secret_key"])

    if access_key && secret_key do
      {:ok,
       %{
         access_key: access_key,
         secret_key: secret_key,
         region: present(creds["aws_region"]) || "us-east-1"
       }}
    else
      {:error, :missing_credentials}
    end
  end

  @doc """
  `{integration_uuid, name}` pairs for every account
  `active_integration_uuids/0` would poll — for the settings UI's
  per-account list, which needs a human-readable name alongside the uuid it
  writes to the tracking/exclusion settings.

  ## Examples

      iex> PhoenixKit.Modules.Emails.AwsIntegrations.active_integrations_with_names()
      [{"019fb9ec-0000-7000-8000-000000000000", "AWS SES .eu"}]
  """
  @spec active_integrations_with_names() :: [{String.t(), String.t()}]
  def active_integrations_with_names do
    active_integration_uuids()
    |> Enum.map(fn uuid ->
      case Integrations.get_integration_by_uuid(uuid) do
        {:ok, %{name: name}} -> {uuid, name}
        _ -> {uuid, uuid}
      end
    end)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
