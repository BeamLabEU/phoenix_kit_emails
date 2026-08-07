defmodule PhoenixKit.Modules.Emails.InterceptorScrubOrderTest do
  @moduledoc """
  The scrubber is only as good as where it sits in the pipeline.

  `extract_body_preview/1` also strips HTML, and `strip_html_tags/1` rewrites
  every HTML entity to a space — so with stripping first, an entity-encoded
  `&amp;token=` arrives at the scrubber as ` token=` and the `&amp;` branch of
  the query pattern can never match. A test that calls `SecretScrubber.scrub/1`
  directly stays green while that path leaks, which is why these assertions go
  through the extraction function itself.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Interceptor

  @token "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE0"

  defp html_email(html), do: %Swoosh.Email{html_body: html, text_body: nil}
  defp text_email(text), do: %Swoosh.Email{text_body: text}

  # A URL written as VISIBLE TEXT in an HTML body is the case that leaks: the
  # tag stripper leaves it in the preview, so the scrubber has to have reached
  # it first. Its entity-encoded `&amp;` is why the ordering matters at all.
  test "an entity-encoded second query parameter in visible text is redacted" do
    preview =
      "<p>Join us at https://app.example.com/users/register?ref=x&amp;invitation=#{@token} today</p>"
      |> html_email()
      |> Interceptor.extract_body_preview()

    refute preview =~ @token
    assert preview =~ "[REDACTED]"
  end

  test "a visible-text reset link in an HTML body is redacted" do
    preview =
      "<p>Reset here: https://app.example.com/users/reset-password/#{@token}</p>"
      |> html_email()
      |> Interceptor.extract_body_preview()

    refute preview =~ @token
    assert preview =~ "[REDACTED]"
  end

  # A URL that lives only in an href disappears with its tag — also safe, and
  # worth pinning so the difference is deliberate rather than discovered later.
  test "a token inside an href leaves no trace at all" do
    preview =
      "<a href=\"https://app.example.com/users/reset-password/#{@token}\">Reset</a>"
      |> html_email()
      |> Interceptor.extract_body_preview()

    refute preview =~ @token
    assert preview =~ "Reset"
  end

  test "a text body is redacted in the preview" do
    preview =
      "Reset: https://app.example.com/users/reset-password/#{@token}"
      |> text_email()
      |> Interceptor.extract_body_preview()

    refute preview =~ @token
    assert preview =~ "[REDACTED]"
  end

  test "a token past the 1000-character window cannot survive by being sliced off" do
    padding = String.duplicate("filler text. ", 90)

    preview =
      "#{padding}https://app.example.com/users/reset-password/#{@token}"
      |> text_email()
      |> Interceptor.extract_body_preview()

    refute preview =~ @token
  end

  test "ordinary HTML content still survives stripping" do
    preview =
      "<p>Your order <strong>#12345</strong> shipped.</p>"
      |> html_email()
      |> Interceptor.extract_body_preview()

    assert preview =~ "Your order"
    assert preview =~ "12345"
    refute preview =~ "<strong>"
  end
end
