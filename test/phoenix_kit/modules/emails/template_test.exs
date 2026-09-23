defmodule PhoenixKit.Modules.Emails.TemplateTest do
  @moduledoc """
  Pure changeset unit tests for the reserved-name guard on `Template`. No DB
  needed — the guard runs entirely on the changeset before any insert.

  `Content.resolve/5`'s layer 1 wins on an active DB row matched by `name`
  alone, so a non-system row claiming one of these names would silently
  hijack a real system email. See `Template.reserved_names/0`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Template

  @all_reserved_names [
    "magic_link",
    "register",
    "reset_password",
    "update_email",
    "test_email",
    "billing_invoice",
    "billing_receipt",
    "billing_credit_note",
    "billing_payment_confirmation",
    "organization_invitation",
    "magic_link_registration",
    "new_login_alert",
    "failed_login_alert"
  ]

  # Called by core's user_notifier.ex but not seeded by this package — no DB
  # row exists on a fresh install, so these are exploitable today via the
  # ordinary "New Template" form (which never sends is_system).
  @unseeded_reserved_names [
    "organization_invitation",
    "magic_link_registration",
    "new_login_alert",
    "failed_login_alert"
  ]

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        name: "some_template",
        slug: "some-template",
        display_name: %{"en" => "Some Template"},
        subject: %{"en" => "Hello"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: "draft"
      },
      overrides
    )
  end

  describe "reserved_names/0" do
    test "returns all 13 reserved names" do
      names = Template.reserved_names()

      assert length(names) == 13
      assert Enum.sort(names) == Enum.sort(@all_reserved_names)
    end
  end

  describe "changeset/2 reserved name validation" do
    test "rejects each unseeded reserved name when is_system is absent" do
      for name <- @unseeded_reserved_names do
        changeset = Template.changeset(%Template{}, valid_attrs(%{name: name}))

        refute changeset.valid?, "expected #{name} without is_system to be invalid"
        assert {msg, _} = Keyword.get(changeset.errors, :name)
        assert msg =~ "reserved"
      end
    end

    test "rejects each unseeded reserved name when is_system is explicitly false" do
      for name <- @unseeded_reserved_names do
        changeset =
          Template.changeset(%Template{}, valid_attrs(%{name: name, is_system: false}))

        refute changeset.valid?, "expected #{name} with is_system: false to be invalid"
        assert {msg, _} = Keyword.get(changeset.errors, :name)
        assert msg =~ "reserved"
      end
    end

    test "accepts each unseeded reserved name when is_system is true" do
      for name <- @unseeded_reserved_names do
        changeset =
          Template.changeset(%Template{}, valid_attrs(%{name: name, is_system: true}))

        assert changeset.valid?,
               "expected #{name} with is_system: true to be valid, got: #{inspect(changeset.errors)}"
      end
    end

    test "rejects renaming a non-reserved template's name to a reserved one when is_system is false" do
      existing = %Template{name: "custom_template", is_system: false}

      changeset = Template.changeset(existing, valid_attrs(%{name: "new_login_alert"}))

      refute changeset.valid?
      assert {msg, _} = Keyword.get(changeset.errors, :name)
      assert msg =~ "reserved"
    end

    test "a non-reserved name is unaffected" do
      changeset = Template.changeset(%Template{}, valid_attrs(%{name: "totally_custom_name"}))

      assert changeset.valid?
    end
  end
end
