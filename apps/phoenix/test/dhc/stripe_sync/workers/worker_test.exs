defmodule Dhc.StripeSync.WorkerTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeSync.Worker

  describe "perform/1 arg validation" do
    test "returns error when customer_ids is not a list" do
      args = %{"customer_ids" => "not_a_list"}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "customer_ids must be an array" in errors
    end

    test "returns error when customer_ids contains non-strings" do
      args = %{"customer_ids" => [123, "cus_abc"]}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "customer_ids must contain only strings" in errors
    end

    test "returns error when customer_ids is a map instead of list" do
      args = %{"customer_ids" => %{"id" => "cus_abc"}}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "customer_ids must be an array" in errors
    end

    test "returns error when customer_ids is a number" do
      args = %{"customer_ids" => 42}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "customer_ids must be an array" in errors
    end

    test "accumulates single validation error for non-string elements" do
      args = %{"customer_ids" => [1, 2, 3]}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "customer_ids must contain only strings" in errors
    end
  end
end
