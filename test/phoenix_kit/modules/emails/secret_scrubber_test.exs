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

    test "email confirmation, email change, magic link, magic-link registration and QR login" do
      for url <- [
            "https://app.example.com/users/confirm/#{@token}",
            # The email-change route core actually registers, hyphenated —
            # `deliver_update_email_instructions/2` sends this one.
            "https://app.example.com/dashboard/settings/confirm-email/#{@token}",
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

  describe "hard input cannot make the scrubber quietly give up" do
    # `String.replace/3` returns the subject UNCHANGED when PCRE exhausts its
    # backtracking limit, so a pattern that can backtrack quadratically fails
    # OPEN: the body sails through with its token intact and the log looks
    # scrubbed. The scheme-anchored pattern this replaced did exactly that once
    # a body carried ~20 KB of slash-heavy text ahead of the real link.
    test "a slash-heavy body ahead of a real reset link is still redacted" do
      noise = "https://app.example.com/" <> String.duplicate("confirm/", 10_000) <> "x"
      body = "#{noise} Reset: https://app.example.com/users/reset-password/#{@token}"

      refute SecretScrubber.scrub(body) =~ @token
    end

    test "and the work that costs grows linearly with the input" do
      link = " Reset: https://app.example.com/users/reset-password/#{@token}"

      # Reductions, not microseconds. The VM charges `re:run/3` reductions in
      # proportion to the matching work it actually performs, so this counts
      # the scrubber's own effort and is blind to how many other tests are
      # fighting for a scheduler. The wall-clock version of this assertion
      # measured the box instead of the code and flapped for it: `async: true`
      # against a busy machine turned a 4x input into a 10x — and under real
      # load a 90x — wall time with nothing wrong in the regex (seen: 100395µs
      # against an 88680µs ceiling). The reduction counts for these two bodies
      # repeat to within ~0.1% run to run, loaded or idle.
      work = fn n ->
        body = String.duplicate("https://app.example.com/confirm/", n) <> link

        # Built before the first reading on purpose: only the scrub is charged.
        {:reductions, before} = Process.info(self(), :reductions)
        out = SecretScrubber.scrub(body)
        {:reductions, later} = Process.info(self(), :reductions)

        refute out =~ @token
        later - before
      end

      # Quadratic backtracking cost ~16x the work for 4x the input; linear
      # matching lands just under 4x, so this bound catches the regression
      # without sitting on top of the honest number.
      assert work.(40_000) < work.(10_000) * 8
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
