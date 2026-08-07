defmodule PhoenixKit.Modules.Emails.SecretScrubber do
  @moduledoc """
  Removes single-use authentication tokens from email bodies before they are
  persisted to the email log.

  ## Why this exists

  PhoenixKit stores only a SHA-256 hash of every emailed token, so the database
  cannot be read to obtain one — the raw token exists in exactly one place, the
  message sent to the user. Logging the message body put it back in the
  database, in plaintext, behind a permission (`emails`) that an operator can
  grant to any role and that the Admin role holds by default.

  That turns the email log into a credential store: request a password reset for
  any address on the public forgot-password page, then read the resulting link
  out of `/admin/emails` and use it. The reader never needs the target's
  mailbox, and the target gets no signal beyond an unexpected email.

  Scrubbing happens on the way IN, not on the way out, so the token never
  reaches the row — a later reader, an export, a backup and a support dump are
  all covered by the one control.

  ## What is scrubbed

  The last path segment of any URL whose path contains a token-bearing segment
  (`reset-password`, `confirm`, `magic-link`, `verify`, `finish`, `invitation`),
  and the value of any `token`/`t` query parameter. Matching on segment NAMES
  rather than whole paths is deliberate: the host application chooses the route
  prefix (`PhoenixKit.Utils.Routes.url/1`), and locale-prefixed twins exist for
  every auth route, so a full-path allowlist would silently go stale.

  The link is left in place with its token replaced, so the log still shows
  which mail was sent and where it pointed.

      iex> PhoenixKit.Modules.Emails.SecretScrubber.scrub(
      ...>   "Reset here: https://example.com/users/reset-password/abc123DEF456ghi789JKL"
      ...> )
      "Reset here: https://example.com/users/reset-password/[REDACTED]"
  """

  @placeholder "[REDACTED]"

  # A token-bearing URL: any http(s) URL whose path passes through one of the
  # auth segments, capturing the final segment as the secret. Tokens are
  # `Base.url_encode64/2` output of 32+ random bytes, so the 16-character floor
  # cannot match an ordinary trailing word while still catching every real one.
  @token_url ~r/
    (https?:\/\/[^\s"'<>\)\]]*?\/
     (?:reset-password|confirm|confirm-email|magic-link|verify|finish|invitations?)
     (?:\/[^\s"'<>\/\)\]]+)*?\/)
    ([A-Za-z0-9_\-=%.]{16,})
  /x

  # `?token=…` / `&t=…` in any URL, including routes not covered above.
  @token_query ~r/([?&](?:token|t|code)=)([^\s"'<>&\)\]]{8,})/i

  @doc """
  Returns `body` with every authentication token replaced by `#{@placeholder}`.

  Non-binary input is returned unchanged so the function can sit directly in a
  pipeline that may carry `nil`.
  """
  @spec scrub(term()) :: term()
  def scrub(body) when is_binary(body) do
    body
    |> String.replace(@token_url, "\\1#{@placeholder}")
    |> String.replace(@token_query, "\\1#{@placeholder}")
  end

  def scrub(body), do: body

  @doc "The string a removed token is replaced with."
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder
end
