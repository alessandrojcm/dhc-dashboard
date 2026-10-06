defmodule Dhc.Stripe.SubscriptionPaymentTest do
  use ExUnit.Case, async: true

  alias Dhc.Stripe.SubscriptionPayment

  describe "request_fields/2" do
    test "builds the common incomplete, auto-charged, invoice-expanded subscription request" do
      assert SubscriptionPayment.request_fields("cus_1", "price_1") == [
               {"customer", "cus_1"},
               {"items[0][price]", "price_1"},
               {"payment_behavior", "default_incomplete"},
               {"collection_method", "charge_automatically"},
               {"expand[]", "latest_invoice.payments"}
             ]
    end
  end

  describe "payment_intent_id/1" do
    test "reads a PaymentIntent id given as a string" do
      assert SubscriptionPayment.payment_intent_id(subscription_with_payment("pi_1")) == "pi_1"
    end

    test "reads a PaymentIntent embedded as an object" do
      assert SubscriptionPayment.payment_intent_id(subscription_with_payment(%{"id" => "pi_2"})) ==
               "pi_2"
    end

    test "uses only the first invoice payment" do
      subscription =
        put_in(subscription_with_payment("pi_first"), ["latest_invoice", "payments", "data"], [
          %{"payment" => %{"payment_intent" => "pi_first"}},
          %{"payment" => %{"payment_intent" => "pi_second"}}
        ])

      assert SubscriptionPayment.payment_intent_id(subscription) == "pi_first"
    end

    test "is nil without payments, without an expanded invoice, or for a non-map" do
      assert SubscriptionPayment.payment_intent_id(%{
               "latest_invoice" => %{"payments" => %{"data" => []}}
             }) == nil

      assert SubscriptionPayment.payment_intent_id(%{"latest_invoice" => "in_unexpanded"}) == nil
      assert SubscriptionPayment.payment_intent_id(%{}) == nil
      assert SubscriptionPayment.payment_intent_id(nil) == nil
    end
  end

  describe "latest_invoice/1" do
    test "returns only an expanded invoice" do
      assert SubscriptionPayment.latest_invoice(%{"latest_invoice" => %{"id" => "in_1"}}) ==
               %{"id" => "in_1"}

      assert SubscriptionPayment.latest_invoice(%{"latest_invoice" => "in_1"}) == nil
      assert SubscriptionPayment.latest_invoice(nil) == nil
    end
  end

  describe "validate_paid_invoice/1" do
    test "accepts a paid invoice" do
      assert :ok = SubscriptionPayment.validate_paid_invoice(invoice("paid"))
    end

    test "rejects an unsettled invoice with its status" do
      assert {:error, {:invoice_unsettled, "open"}} =
               SubscriptionPayment.validate_paid_invoice(invoice("open"))
    end

    test "rejects a missing or unexpanded invoice" do
      assert {:error, :invoice_payment_missing} = SubscriptionPayment.validate_paid_invoice(%{})

      assert {:error, :invoice_payment_missing} =
               SubscriptionPayment.validate_paid_invoice(%{"latest_invoice" => "in_1"})
    end
  end

  describe "classify_payment_intent/1" do
    test "classifies every PaymentIntent state either caller maps" do
      assert SubscriptionPayment.classify_payment_intent(%{"status" => "succeeded"}) ==
               :succeeded

      assert SubscriptionPayment.classify_payment_intent(pi("requires_confirmation")) ==
               {:requires_confirmation, "pi_1"}

      assert SubscriptionPayment.classify_payment_intent(pi("processing")) ==
               {:processing, "pi_1"}

      assert SubscriptionPayment.classify_payment_intent(
               Map.put(pi("requires_action"), "next_action", %{
                 "type" => "verify_with_microdeposits"
               })
             ) == {:requires_action, "pi_1", "verify_with_microdeposits"}

      assert SubscriptionPayment.classify_payment_intent(pi("requires_action")) ==
               {:requires_action, "pi_1", nil}

      for status <- ["requires_payment_method", "requires_capture", "canceled"] do
        assert SubscriptionPayment.classify_payment_intent(pi(status)) ==
                 {:failed, "pi_1", status}
      end

      assert SubscriptionPayment.classify_payment_intent(pi("new_status")) ==
               {:unrecognized, "pi_1", "new_status"}
    end

    test "treats anything that is not a PaymentIntent with an id and status as invalid" do
      assert SubscriptionPayment.classify_payment_intent(%{"status" => "processing"}) == :invalid

      assert SubscriptionPayment.classify_payment_intent(%{"status" => "requires_confirmation"}) ==
               :invalid

      assert SubscriptionPayment.classify_payment_intent(%{"id" => "pi_1"}) == :invalid
      assert SubscriptionPayment.classify_payment_intent(nil) == :invalid
    end
  end

  defp subscription_with_payment(payment_intent) do
    %{
      "latest_invoice" => %{
        "payments" => %{"data" => [%{"payment" => %{"payment_intent" => payment_intent}}]}
      }
    }
  end

  defp invoice(status), do: %{"latest_invoice" => %{"id" => "in_1", "status" => status}}
  defp pi(status), do: %{"id" => "pi_1", "status" => status}
end
