defmodule Dhc.Invitations.PricingTest do
  use ExUnit.Case, async: true

  alias Dhc.Invitations.Pricing
  alias Dhc.StripeHTTPStub

  test "a missing backend-applied tier coupon degrades to tier_coupon_not_configured" do
    # Regression for the 2026-08-24 coach-invitation incident: STRIPE_COACH_COUPON_ID
    # pointed at a coupon name instead of its live coupon ID, so retrieval 404'd,
    # the failure was treated as a provider error, and cleanup retries stormed Stripe.
    stub_membership_prices()

    StripeHTTPStub.expect("GET", "/v1/coupons/DHC_COACH_TIER", fn conn ->
      StripeHTTPStub.stripe_error(conn, 404, %{
        "code" => "resource_missing",
        "message" => "No such coupon: 'DHC_COACH_TIER'",
        "param" => "coupon"
      })
    end)

    assert {:error, :tier_coupon_not_configured} =
             Pricing.membership_payment_plan({:coupon, "DHC_COACH_TIER", [:monthly, :annual]})
  end

  test "other Stripe failures from tier coupon retrieval pass through unchanged" do
    stub_membership_prices()

    StripeHTTPStub.expect("GET", "/v1/coupons/DHC_STUDENT_TIER", fn conn ->
      StripeHTTPStub.json(conn, 500, %{"error" => %{"type" => "api_error"}})
    end)

    assert {:error, {:stripe, {:stripe_api, 500, %{"error" => %{"type" => "api_error"}}}}} =
             Pricing.membership_payment_plan({:coupon, "DHC_STUDENT_TIER", [:monthly]})
  end

  defp stub_membership_prices do
    # The monthly and annual membership prices are resolved by lookup key
    # before any tier coupon is retrieved.
    StripeHTTPStub.stub("GET", "/v1/prices", fn conn ->
      StripeHTTPStub.json(conn, %{
        "object" => "list",
        "has_more" => false,
        "data" => [
          %{
            "id" => "price_#{StripeHTTPStub.query(conn)["lookup_keys[]"]}",
            "product" => "prod_membership"
          }
        ]
      })
    end)
  end
end
