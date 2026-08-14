defmodule PhoenixKit.Modules.Emails.Web.DaisyUI5FormIdiomTest do
  @moduledoc """
  The daisyUI 5 conversion is invisible when it regresses: v4 classes such as
  `form-control`, `label-text`, `input-group` and `btn-group` match no rule
  in the shipped v5 bundle, so captions go back to 60% opacity and grouped
  buttons lose their shared border. Scan the templates rather than waiting
  for a screenshot.
  """

  use ExUnit.Case, async: true

  @heex Path.wildcard("lib/**/*.heex")

  @converted [
    "lib/phoenix_kit/modules/emails/web/blocklist.html.heex",
    "lib/phoenix_kit/modules/emails/web/email_tracking.html.heex",
    "lib/phoenix_kit/modules/emails/web/emails.html.heex",
    "lib/phoenix_kit/modules/emails/web/metrics.html.heex",
    "lib/phoenix_kit/modules/emails/web/template_editor.html.heex",
    "lib/phoenix_kit/modules/emails/web/templates.html.heex"
  ]

  # Classes daisyUI 5 removed. Comments in the templates mention them on
  # purpose; only a class attribute is a leftover.
  @dead_v4_class ~r/\bclass="[^"]*\b(form-control|label-text|label-text-alt|input-bordered|input-group|btn-group)\b/

  test "no daisyUI 4 form class that the shipped v5 bundle has no rule for" do
    leftovers =
      for path <- @heex,
          content = File.read!(path),
          Regex.match?(@dead_v4_class, content),
          do: path

    assert leftovers == [],
           "dead daisyUI 4 classes still in class attributes: #{inspect(leftovers)}"
  end

  test "the six converted pages use real fieldset/legend" do
    for path <- @converted do
      content = File.read!(path)
      refute content =~ ~s|div class="fieldset|, "#{path} still has a div.fieldset"
      assert content =~ "<fieldset", "#{path} is missing a <fieldset>"
      assert content =~ "fieldset-legend", "#{path} is missing fieldset-legend"
    end
  end

  test "template editor preview toggle uses join, not btn-group" do
    content = File.read!("lib/phoenix_kit/modules/emails/web/template_editor.html.heex")
    refute content =~ "btn-group"
    assert content =~ ~s|class="join"|
    assert content =~ "join-item"
  end

  test "template editor field errors are bound to their control" do
    content = File.read!("lib/phoenix_kit/modules/emails/web/template_editor.html.heex")

    for id <- [
          "template-name-error",
          "template-display-name-error",
          "template-slug-error",
          "template-category-error",
          "template-status-error",
          "template-description-error",
          "template-subject-error",
          "template-html-body-error",
          "template-text-body-error",
          "test-recipient-error"
        ] do
      assert content =~ ~s|id="#{id}"|, "missing error id #{id}"
      assert content =~ ~s|"#{id}"|, "nothing references #{id}"
    end
  end
end
