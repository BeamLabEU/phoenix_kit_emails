defmodule PhoenixKit.Modules.Emails.SecretScrubberTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.SecretScrubber

  doctest PhoenixKit.Modules.Emails.SecretScrubber

  # Shaped like the real thing: `Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`.
  @token "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE0"

  describe "auth links the log must not keep" do
    test "password reset" do
      body = "Reset your password: https://app.example.com/users/reset-password/#{@token}"

      scrubbed = SecretScrubber.scrub(body)

      refute scrubbed =~ @token

      assert scrubbed ==
               "Reset your password: https://app.example.com/users/reset-password/[REDACTED]"
    end

    test "email confirmation, magic link, magic-link registration and QR login" do
      for url <- [
            "https://app.example.com/users/confirm/#{@token}",
            "https://app.example.com/users/magic-link/#{@token}",
            "https://app.example.com/users/register/verify/#{@token}",
            "https://app.example.com/users/qr-login/finish/#{@token}"
          ] do
        scrubbed = SecretScrubber.scrub("Click #{url} to continue")

        refute scrubbed =~ @token, "token survived in #{url}"
        assert scrubbed =~ "[REDACTED]"
      end
    end

    test "a host-chosen route prefix and a locale-prefixed twin" do
      for url <- [
            "https://app.example.com/phoenix_kit/users/reset-password/#{@token}",
            "https://app.example.com/et/users/reset-password/#{@token}"
          ] do
        refute SecretScrubber.scrub(url) =~ @token
      end
    end

    test "an organisation invitation, whose path carries no auth segment at all" do
      # Core builds this as `/users/register?invitation=<token>` — the path
      # pattern cannot see it, so the parameter name has to.
      body = """
      Acme Ltd has invited you to join their organization.

      To accept the invitation, register an account by visiting the link below:

      https://app.example.com/users/register?invitation=#{@token}

      This invitation link will expire in 7 days.
      """

      scrubbed = SecretScrubber.scrub(body)

      refute scrubbed =~ @token
      assert scrubbed =~ "?invitation=[REDACTED]"
    end

    test "a token in a second query parameter of an HTML link, entity-encoded" do
      body =
        ~s|<a href="https://app.example.com/users/register?ref=x&amp;invitation=#{@token}">Join</a>|

      scrubbed = SecretScrubber.scrub(body)

      refute scrubbed =~ @token
      assert scrubbed =~ "invitation=[REDACTED]"
    end

    test "a token carried as a query parameter" do
      body = "Open https://app.example.com/invite?token=#{@token}&ref=newsletter"

      scrubbed = SecretScrubber.scrub(body)

      refute scrubbed =~ @token
      assert scrubbed =~ "token=[REDACTED]"
      # Ordinary parameters keep their values — the log still shows what was sent.
      assert scrubbed =~ "ref=newsletter"
    end

    test "several links in one body, in HTML" do
      body = """
      <p>Hello,</p>
      <a href="https://app.example.com/users/reset-password/#{@token}">Reset</a>
      <a href="https://app.example.com/users/confirm/#{@token}">Confirm</a>
      """

      scrubbed = SecretScrubber.scrub(body)

      refute scrubbed =~ @token
      assert scrubbed |> String.split("[REDACTED]") |> length() == 3
    end
  end

  describe "what the log keeps" do
    test "the link itself, so the row still shows what was sent and where" do
      scrubbed =
        SecretScrubber.scrub("Go to https://app.example.com/users/reset-password/#{@token}")

      assert scrubbed =~ "https://app.example.com/users/reset-password/"
    end

    test "ordinary prose and unrelated links are untouched" do
      body = """
      Your order #12345 shipped. Track it at https://app.example.com/orders/12345
      or reply to this email. See https://example.com/help/confirm-delivery for details.
      """

      assert SecretScrubber.scrub(body) == body
    end

    test "a short trailing segment on an auth-shaped path is not a token" do
      body = "https://app.example.com/users/confirm/ok"

      assert SecretScrubber.scrub(body) == body
    end
  end

  describe "input handling" do
    test "passes non-binary values through so it can sit in a nil-carrying pipeline" do
      assert SecretScrubber.scrub(nil) == nil
      assert SecretScrubber.scrub(42) == 42
    end

    test "empty body" do
      assert SecretScrubber.scrub("") == ""
    end
  end
end
