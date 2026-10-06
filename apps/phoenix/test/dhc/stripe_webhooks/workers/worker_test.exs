defmodule Dhc.StripeWebhooks.WorkerTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeWebhooks.Worker

  describe "perform/1 with valid args" do
    test "returns :ok for an invoice event without a customer" do
      event_data = %{
        "type" => "invoice.paid",
        "data" => %{"object" => %{"id" => "in_test_123"}}
      }

      args = %{
        "event_type" => "invoice.paid",
        "event_id" => "evt_test_123",
        "event_data" => event_data
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "returns :ok for unknown event type (acknowledged)" do
      event_data = %{
        "type" => "account.updated",
        "data" => %{"object" => %{"id" => "acct_123"}}
      }

      args = %{
        "event_type" => "account.updated",
        "event_id" => "evt_unknown_123",
        "event_data" => event_data
      }

      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end

    test "returns the routed target's error for a subscription event without a customer" do
      event_data = %{
        "type" => "customer.subscription.updated",
        "data" => %{"object" => %{"id" => "sub_no_customer"}}
      }

      args = %{
        "event_type" => "customer.subscription.updated",
        "event_id" => "evt_no_customer",
        "event_data" => event_data
      }

      assert {:error, :missing_customer_id} = Worker.perform(%Oban.Job{args: args})
    end
  end

  describe "uniqueness" do
    test "is unique on event_id for 24 hours across all job states" do
      changeset = Worker.new(%{"event_type" => "invoice.paid", "event_id" => "evt_1"})

      assert %{keys: [:event_id], period: 86_400, states: states} =
               Ecto.Changeset.get_change(changeset, :unique)

      assert Enum.sort(states) == Enum.sort(Oban.Job.states())
    end
  end

  describe "perform/1 with invalid args" do
    test "returns error when event_type is missing" do
      args = %{"event_id" => "evt_123", "event_data" => %{}}

      assert {:error, :invalid_args} = Worker.perform(%Oban.Job{args: args})
    end

    test "returns error when event_id is missing" do
      # Missing event_id — falls to catch-all clause since pattern requires both keys
      args = %{"event_type" => "invoice.paid", "event_data" => %{}}

      assert {:error, :invalid_args} = Worker.perform(%Oban.Job{args: args})
    end
  end
end
