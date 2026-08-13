defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTrackingTest do
  @moduledoc """
  Render tests for the "Email Tracking" settings section.

  The section had no test at all when its markup was moved from the v4
  `form-control` / `label-text` idiom to daisyUI 5 `fieldset`. Those three
  classes have no rule in the shipped v5 bundle, so a regression here is
  invisible — nothing breaks, the captions simply go back to being drawn by
  `.label` alone. Hence the explicit `refute`s on the dead class names.

  This package ships no Endpoint/Router, so the component is rendered through
  `render_component/3` against the test stub endpoint rather than a live
  connection.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Queue

  describe "the section renders" do
    test "with no email settings at all" do
      html = render_section()

      assert html =~ "System status"
      assert html =~ "Save Email Bodies"
      assert html =~ "Save Email Headers"
      assert html =~ "Emails Sampling Rate"
      assert html =~ "Email Retention Period"
      assert html =~ "Data Privacy Notice"
    end

    test "the queue switches are on the page" do
      html = render_section()

      assert html =~ ~s|name="email_tracking[queue_enabled]"|
      assert html =~ "Queue Outgoing Emails"
    end

    test "the auth-mail switch appears only while the queue itself is on" do
      # The queue is on by default, so this one has to be switched off first.
      {:ok, _} = Queue.set_enabled(false)
      refute render_section() =~ "Queue Authentication Emails Too"

      {:ok, _} = Queue.set_enabled(true)
      assert render_section() =~ "Queue Authentication Emails Too"
    end

    test "the numeric controls keep their names, bounds and events" do
      html = render_section()

      assert html =~ ~s|name="sampling_rate"|
      assert html =~ ~s|phx-blur="update_email_sampling_rate"|
      assert html =~ ~s|name="retention_days"|
      assert html =~ ~s|phx-blur="update_email_retention"|
      assert html =~ ~s|max="100"|
      assert html =~ ~s|max="365"|
    end

    test "the maintenance buttons are wired to their events" do
      html = render_section()

      assert html =~ "Run Cleanup Now"
      assert html =~ ~s|phx-click="run_cleanup_now"|
    end

    test "compression only shows up while bodies are being saved" do
      refute render_section() =~ "Compress Now"

      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      assert html =~ "Compress Email Bodies After"
      assert html =~ "Compress Now"
      assert html =~ ~s|name="compress_days"|
      assert html =~ ~s|phx-blur="update_compress_days"|
    end

    test "S3 archival is shown as unavailable rather than as a working switch" do
      html = render_section()

      assert html =~ "Enable S3 Archival"
      assert html =~ "In development"
      assert html =~ "Not available yet"

      # The uploader is not wired to anything, so the box must not be clickable
      # — a toggle that flips and does nothing is worse than a disabled one.
      assert [checkbox] =
               Regex.run(~r|<input type="checkbox"[^>]*archive_to_s3[^>]*>|, html) ||
                 Regex.run(~r|<input[^>]*name="email_tracking\[archive_to_s3\]"[^>]*>|, html)

      assert checkbox =~ "disabled"
    end
  end

  describe "daisyUI 5 form idiom" do
    test "no v4 class that the shipped bundle has no rule for" do
      html = render_section()

      refute html =~ "form-control"
      refute html =~ "label-text"
      refute html =~ "input-bordered"
      refute html =~ "input-group"
    end

    test "fields are grouped by fieldset/legend" do
      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      assert html =~ "fieldset-legend"

      # `<legend>` names the GROUP, not the field, so each control repeats the
      # caption as an aria-label — otherwise the inputs are unnamed to a
      # screen reader.
      assert html =~ ~s|aria-label="Emails Sampling Rate"|
      assert html =~ ~s|aria-label="Email Retention Period"|
      assert html =~ ~s|aria-label="Compress Email Bodies After"|
    end

    test "unit suffixes use the input/label idiom, not a half-styled join" do
      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      # daisyUI 5 draws the suffix through `.label:is(.input > *, .select > *)`:
      # the LABEL carries `.input` (one border, correct radii, a divider) and
      # the unit is a `.label` span inside it. A `.join` around a bare `.input`
      # left the suffix square and borderless — the input-group of v4 in all
      # but name.
      refute html =~ "join-item"

      for unit <- ["%", "days"] do
        assert Regex.match?(
                 ~r|<label[^>]*\bclass="[^"]*\binput\b[^"]*"[^>]*>.*?<span class="label">\s*#{Regex.escape(unit)}\s*</span>|s,
                 html
               ),
               "expected an .input label wrapping the #{unit} suffix"
      end

      # `.fieldset` is a grid: a width-less flex child stretches the column
      # instead of hugging its input. Read out of the class list rather than
      # matched as a string — the order the classes are written in is not the
      # thing under test.
      input_labels =
        ~r|<label[^>]*\bclass="([^"]*)"|
        |> Regex.scan(html)
        |> Enum.map(fn [_, classes] -> String.split(classes) end)
        |> Enum.filter(&("input" in &1))

      assert length(input_labels) == 3
      assert Enum.all?(input_labels, &("w-32" in &1))
    end
  end

  defp render_section do
    render_component(
      PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking,
      %{id: "email-tracking"},
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end
end
