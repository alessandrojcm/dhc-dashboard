defmodule Dhc.E2EOnboardingStripeAdapter do
  @moduledoc false

  @behaviour Dhc.Onboarding.StripeAdapter

  @impl true
  def preview_membership(coupon_code) do
    complimentary? = coupon_code == "COMPLIMENTARY"

    {:ok,
     %{
       proratedPrice: money(if(complimentary?, do: 0, else: 10_000)),
       proratedMonthlyPrice: money(if(complimentary?, do: 0, else: 2_000)),
       proratedAnnualPrice: money(if(complimentary?, do: 0, else: 8_000)),
       monthlyFee: money(2_000),
       annualFee: money(8_000),
       discountPercentage: if(complimentary?, do: 100, else: 0)
     }}
  end

  @impl true
  def prepare_payment(coupon_code) do
    {:ok,
     %{
       requirement: if(coupon_code == "COMPLIMENTARY", do: :complimentary, else: :paid),
       monthly_price_id: "price_e2e_monthly",
       annual_price_id: "price_e2e_annual",
       promotion_code_id: if(coupon_code, do: "promo_e2e"),
       migration?: false
     }}
  end

  @impl true
  def create_customer(_attrs), do: {:ok, "cus_e2e_onboarding"}

  @impl true
  def provision_membership(_attrs) do
    {:ok,
     %{
       "monthly_subscription_id" => "sub_e2e_monthly",
       "annual_subscription_id" => "sub_e2e_annual"
     }}
  end

  @impl true
  def cancel_membership(_stripe_state), do: :ok

  @impl true
  def retryable_failure?(_reason), do: false

  defp money(amount), do: %{amount: amount, currency: "EUR", precision: 2}
end
