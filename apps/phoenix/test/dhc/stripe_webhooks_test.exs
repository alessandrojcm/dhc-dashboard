defmodule Dhc.StripeWebhooksTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeWebhooks

  describe "allowed_event_types/0" do
    test "returns a non-empty list of event type strings" do
      types = StripeWebhooks.allowed_event_types()

      assert is_list(types)
      assert length(types) > 0
      assert Enum.all?(types, &is_binary/1)
    end

    test "includes core charge event types" do
      types = StripeWebhooks.allowed_event_types()

      assert "charge.succeeded" in types
      assert "charge.expired" in types
      assert "charge.refunded" in types
    end

    test "includes core subscription event types" do
      types = StripeWebhooks.allowed_event_types()

      assert "customer.subscription.created" in types
      assert "customer.subscription.updated" in types
      assert "customer.subscription.deleted" in types
    end
  end

  describe "process_event/1" do
    test "returns :ok for unhandled event type (not in allowed list)" do
      event = %{
        "type" => "account.updated",
        "data" => %{"object" => %{"id" => "acct_123"}}
      }

      assert :ok = StripeWebhooks.process_event(event)
    end

    test "returns error for event without data.object" do
      event = %{"type" => "charge.succeeded"}

      assert {:error, :missing_data_object} = StripeWebhooks.process_event(event)
    end

    test "returns error for malformed event" do
      assert {:error, :malformed_event} = StripeWebhooks.process_event("not a map")
    end

    test "returns error for subscription event without customer ID" do
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{"object" => %{"id" => "sub_123"}}
      }

      assert {:error, :missing_customer_id} = StripeWebhooks.process_event(event)
    end

    test "returns error for subscription event with empty customer" do
      event = %{
        "type" => "customer.subscription.updated",
        "data" => %{"object" => %{"id" => "sub_123", "customer" => ""}}
      }

      assert {:error, :missing_customer_id} = StripeWebhooks.process_event(event)
    end

    test "returns :ok for charge.succeeded without workshop metadata" do
      event = %{
        "type" => "charge.succeeded",
        "data" => %{"object" => %{"id" => "ch_no_meta"}}
      }

      # No workshop metadata and no customer ID — just :ok
      assert :ok = StripeWebhooks.process_event(event)
    end

    test "returns :ok for charge.expired without workshop metadata" do
      event = %{
        "type" => "charge.expired",
        "data" => %{"object" => %{"id" => "ch_expired_no_meta"}}
      }

      assert :ok = StripeWebhooks.process_event(event)
    end
  end
end
