defmodule Dhc.StripeWebhooks.WorkerTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeWebhooks.Worker

  describe "perform/1 with valid args" do
    test "returns :ok for known charge.succeeded event" do
      event_data = %{
        "type" => "charge.succeeded",
        "data" => %{
          "object" => %{
            "id" => "ch_test_123",
            "amount" => 2000,
            "metadata" => %{}
          }
        }
      }

      args = %{
        "event_type" => "charge.succeeded",
        "event_id" => "evt_test_123",
        "event_data" => event_data
      }

      # This will attempt DB operations which may fail in test without setup,
      # but the worker should handle it gracefully since there's no matching
      # registration for the charge ID
      result = Worker.perform(%Oban.Job{args: args})

      # The worker should return :ok for a charge with no workshop metadata
      assert result == :ok
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

    test "returns error for charge.succeeded without customer or metadata (graceful)" do
      event_data = %{
        "type" => "charge.succeeded",
        "data" => %{
          "object" => %{
            "id" => "ch_no_metadata"
          }
        }
      }

      args = %{
        "event_type" => "charge.succeeded",
        "event_id" => "evt_no_meta",
        "event_data" => event_data
      }

      # Should return :ok since there's no workshop metadata and no customer
      assert Worker.perform(%Oban.Job{args: args}) == :ok
    end
  end

  describe "perform/1 with invalid args" do
    test "returns error when event_type is missing" do
      args = %{"event_id" => "evt_123", "event_data" => %{}}

      assert {:error, :invalid_args} = Worker.perform(%Oban.Job{args: args})
    end

    test "returns error when event_id is missing" do
      # Missing event_id — falls to catch-all clause since pattern requires both keys
      args = %{"event_type" => "charge.succeeded", "event_data" => %{}}

      assert {:error, :invalid_args} = Worker.perform(%Oban.Job{args: args})
    end
  end
end
