defmodule PhoenixKit.Modules.Emails.UtilsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Utils

  doctest Utils, only: [parse_int: 3]

  describe "parse_int/3" do
    test "a well-formed integer string is returned as is" do
      assert Utils.parse_int("3", 1) == 3
      assert Utils.parse_int(" 42 ", 1) == 42
    end

    test "an integer passes through — LiveView event payloads arrive typed" do
      assert Utils.parse_int(7, 1) == 7
    end

    test "anything that is not a whole integer falls back to the default" do
      for value <- ["abc", "", "   ", "2abc", "1.5", "1e3", "--1", nil, 1.5, %{}, ["1"]] do
        assert Utils.parse_int(value, 25) == 25, "expected default for #{inspect(value)}"
      end
    end

    test "a value below :min falls back to the default" do
      assert Utils.parse_int("0", 1, min: 1) == 1
      assert Utils.parse_int("-1", 1, min: 1) == 1
      assert Utils.parse_int(-5, 25, min: 1) == 25
      assert Utils.parse_int("0", 7, min: 0) == 0
    end

    test "a value above :max is clamped to it" do
      assert Utils.parse_int("101", 25, min: 1, max: 100) == 100
      assert Utils.parse_int(String.duplicate("9", 40), 1, min: 1, max: 1_000_000) == 1_000_000
      assert Utils.parse_int("100", 25, min: 1, max: 100) == 100
    end

    test "without bounds any integer is accepted" do
      assert Utils.parse_int("-3", 1) == -3
      assert Utils.parse_int("0", 1) == 0
    end
  end
end
