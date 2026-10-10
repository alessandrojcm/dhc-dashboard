defmodule Dhc.StripeWebhooksTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeWebhooks

  @acceptance :acceptance
  @membership_required {:stripe_sync, :customer_required}
  @membership_optional {:stripe_sync, :customer_optional}
  @workshop_refund :workshop_refund
  @intake_complete {:beginners_intake, :complete_payment}
  @intake_release {:beginners_intake, :release_payment}

  @expected_routes %{
    "customer.subscription.created" => [@acceptance, @membership_required],
    "customer.subscription.updated" => [@acceptance, @membership_required],
    "customer.subscription.deleted" => [@acceptance, @membership_required],
    "customer.subscription.paused" => [@acceptance, @membership_required],
    "customer.subscription.resumed" => [@acceptance, @membership_required],
    "customer.subscription.pending_update_applied" => [@acceptance, @membership_required],
    "customer.subscription.pending_update_expired" => [@acceptance, @membership_required],
    "customer.subscription.trial_will_end" => [@acceptance, @membership_required],
    "invoice.paid" => [@acceptance, @membership_optional],
    "invoice.payment_failed" => [@acceptance, @membership_optional],
    "invoice.payment_action_required" => [@acceptance, @membership_optional],
    "invoice.upcoming" => [@acceptance, @membership_optional],
    "invoice.marked_uncollectible" => [@acceptance, @membership_optional],
    "invoice.payment_succeeded" => [@acceptance, @membership_optional],
    "payment_intent.succeeded" => [@acceptance, @membership_optional],
    "payment_intent.payment_failed" => [@acceptance, @membership_optional],
    "payment_intent.canceled" => [@acceptance, @membership_optional],
    "refund.created" => [@workshop_refund],
    "refund.updated" => [@workshop_refund],
    "refund.failed" => [@workshop_refund],
    "checkout.session.completed" => [@intake_complete],
    "checkout.session.expired" => [@intake_release]
  }

  describe "routing table" do
    test "routes every handled event type to exactly its targets" do
      assert StripeWebhooks.routes() == @expected_routes
    end

    test "allowed_event_types/0 is exactly the table's event types" do
      assert Enum.sort(StripeWebhooks.allowed_event_types()) ==
               @expected_routes |> Map.keys() |> Enum.sort()
    end

    test "only subscription, invoice and PaymentIntent events reach Acceptance reconciliation" do
      for {type, targets} <- StripeWebhooks.routes() do
        acceptance_prefix? =
          String.starts_with?(type, ["customer.subscription.", "invoice.", "payment_intent."])

        assert @acceptance in targets == acceptance_prefix?, "unexpected route for #{type}"
      end
    end

    test "charge events are not routed" do
      refute Enum.any?(StripeWebhooks.allowed_event_types(), &String.starts_with?(&1, "charge."))
    end
  end

  describe "process_event/1" do
    test "acknowledges an unknown event type" do
      event = %{
        "type" => "account.updated",
        "data" => %{"object" => %{"id" => "acct_123"}}
      }

      assert :ok = StripeWebhooks.process_event(event)
    end

    test "acknowledges charge events as unknown" do
      for type <- ["charge.succeeded", "charge.expired", "charge.refunded"] do
        event = %{
          "type" => type,
          "data" => %{"object" => %{"id" => "ch_123", "customer" => "cus_charge"}}
        }

        assert :ok = StripeWebhooks.process_event(event)
      end
    end

    test "a subscription event without a customer is an error" do
      for customer <- [nil, ""] do
        event = %{
          "type" => "customer.subscription.updated",
          "data" => %{"object" => %{"id" => "sub_123", "customer" => customer}}
        }

        assert {:error, :missing_customer_id} = StripeWebhooks.process_event(event)
      end
    end

    test "invoice and PaymentIntent events without a customer are a no-op" do
      for type <- ["invoice.paid", "payment_intent.succeeded"] do
        event = %{"type" => type, "data" => %{"object" => %{"id" => "obj_123"}}}

        assert :ok = StripeWebhooks.process_event(event)
      end
    end

    test "returns error for event without data.object" do
      event = %{"type" => "customer.subscription.created"}

      assert {:error, :missing_data_object} = StripeWebhooks.process_event(event)
    end

    test "returns error for malformed event" do
      assert {:error, :malformed_event} = StripeWebhooks.process_event("not a map")
    end
  end
end
