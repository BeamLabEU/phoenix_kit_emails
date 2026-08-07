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
  and the value of a `token` / `t` / `code` / `invitation` / `invite` query
  parameter. Matching on segment NAMES rather than whole paths is deliberate:
  the host application chooses the route prefix
  (`PhoenixKit.Utils.Routes.url/1`), and locale-prefixed twins exist for every
  auth route, so a full-path allowlist would silently go stale.

  Both forms are needed because core uses both: password reset, confirmation,
  email change, magic link and magic-link registration put the token in a path
  segment, while an organisation invitation puts it in `?invitation=` on
  `/users/register` — a path carrying no auth segment whatsoever.

  ## What is deliberately NOT scrubbed

  The send queue. `PhoenixKit.Modules.Emails.Queue.serialize/1` writes the body
  into `oban_jobs.args`, and `SendJob` deserialises those args to perform the
  ACTUAL delivery — scrubbing there would mail the recipient a `[REDACTED]`
  link instead of a working one. The queue is the message in transit, not a
  copy of it. Auth mail stays out of the queue by default
  (`auth_mail_excluded?/1`, setting `email_queue_auth_mail`, default off); an
  operator who turns that on accepts live tokens sitting in `oban_jobs` for the
  lifetime of the job row, which is a retention decision, not something a
  scrubber can fix.

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
  #
  # `invitation` earns its place by name: core sends organisation invitations as
  # `/users/register?invitation=<token>` (`Users.Invitations.maybe_send_invitation_email/3`),
  # a path with no auth segment at all, so the path pattern above cannot see it.
  # It is a 7-day single-use bearer that registers the invited address — exactly
  # the kind of credential this module exists to keep out of the log.
  #
  # `&amp;` is accepted alongside `?`/`&` because an HTML body carries the
  # entity-encoded form, and a token in the SECOND query parameter would
  # otherwise be preceded by `;` and slip past.
  @token_query ~r/((?:[?&]|&amp;)(?:token|t|code|invitation|invite)=)([^\s"'<>&\)\]]{8,})/i

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
