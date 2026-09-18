defmodule Dhc.Inventory.PageParamsTest do
  use ExUnit.Case, async: true

  alias Dhc.Inventory.PageParams

  describe "parse_limit/1" do
    test "defaults nil and blank to 25" do
      assert PageParams.parse_limit(nil) == {:ok, 25}
      assert PageParams.parse_limit("") == {:ok, 25}
    end

    test "accepts the allowed integers and their string forms" do
      assert PageParams.parse_limit(10) == {:ok, 10}
      assert PageParams.parse_limit("50") == {:ok, 50}
    end

    test "rejects anything else" do
      assert PageParams.parse_limit(7) == {:error, :invalid_limit}
      assert PageParams.parse_limit("nope") == {:error, :invalid_limit}
      assert PageParams.parse_limit(1.5) == {:error, :invalid_limit}
    end
  end

  describe "parse_direction/2" do
    test "defaults nil and blank to asc, or to the given default" do
      assert PageParams.parse_direction(nil) == {:ok, "asc"}
      assert PageParams.parse_direction("") == {:ok, "asc"}
      assert PageParams.parse_direction(nil, "desc") == {:ok, "desc"}
    end

    test "accepts asc and desc" do
      assert PageParams.parse_direction("asc") == {:ok, "asc"}
      assert PageParams.parse_direction("desc", "asc") == {:ok, "desc"}
    end

    test "rejects anything else" do
      assert PageParams.parse_direction("up") == {:error, :invalid_direction}
      assert PageParams.parse_direction(:asc) == {:error, :invalid_direction}
    end
  end

  describe "blank_to_nil/1" do
    test "turns nil and whitespace-only strings into nil" do
      assert PageParams.blank_to_nil(nil) == nil
      assert PageParams.blank_to_nil("") == nil
      assert PageParams.blank_to_nil("   ") == nil
    end

    test "keeps non-blank strings trimmed and drops other values" do
      assert PageParams.blank_to_nil("hello") == "hello"
      assert PageParams.blank_to_nil("  hello ") == "hello"
      assert PageParams.blank_to_nil(1) == nil
    end
  end
end
