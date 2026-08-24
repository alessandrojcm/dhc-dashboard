defmodule Dhc.Onboarding.StripeAdapter.Test do
  @moduledoc false

  @behaviour Dhc.Onboarding.StripeAdapter

  @impl true
  def preview_membership(discount_reference) do
    send(test_pid(), {:preview_membership, discount_reference})
    {:ok, %{proratedPrice: %{amount: 0}}}
  end

  @impl true
  def prepare_payment(discount_reference) do
    send(test_pid(), {:prepare_payment, discount_reference})

    case Application.get_env(:dhc, :onboarding_stripe_prepare_result) do
      nil ->
        {:ok,
         %{
           requirement: payment_requirement(discount_reference),
           monthly_price_id: "price_monthly_onboarding",
           annual_price_id: "price_annual_onboarding",
           coupon_id: coupon_id(discount_reference),
           promotion_code_id: promotion_code_id(discount_reference),
           migration?: false,
           # Simulates a product-scoped coupon (the student tier's monthly-only
           # discount) resolved by Dhc.Invitations.Pricing.
           discount_targets: discount_targets(discount_reference)
         }}

      result when is_function(result, 0) ->
        result.()

      result ->
        result
    end
  end

  @impl true
  def create_customer(attrs) do
    send(test_pid(), {:create_customer, attrs})
    Application.get_env(:dhc, :onboarding_stripe_customer_result, {:ok, "cus_onboarding"})
  end

  @impl true
  def provision_membership(attrs) do
    send(test_pid(), {:provision_membership, attrs})

    with :ok <- report_progress(attrs) do
      case Application.get_env(:dhc, :onboarding_stripe_result, {:ok, %{}}) do
        result when is_function(result, 0) -> result.()
        result -> result
      end
    end
  end

  @impl true
  def cancel_membership(stripe_state) do
    send(test_pid(), {:cancel_membership, stripe_state})
    Application.get_env(:dhc, :onboarding_stripe_cancel_result, :ok)
  end

  @impl true
  def retryable_failure?(reason), do: Dhc.Invitations.StripePayment.retryable_failure?(reason)

  defp report_progress(%{progress: progress}) when is_function(progress, 1) do
    progress.(
      Application.get_env(:dhc, :onboarding_stripe_progress, %{
        "setup_intent_id" => "seti_onboarding",
        "monthly_subscription_id" => "sub_monthly_onboarding"
      })
    )
  end

  defp report_progress(_attrs), do: :ok

  defp coupon_id({:coupon, id, _targets}), do: id
  defp coupon_id(_discount_reference), do: nil

  defp payment_requirement("COMPLIMENTARY"), do: :complimentary
  defp payment_requirement({:coupon, _id, [:monthly, :annual]}), do: :complimentary
  defp payment_requirement(_discount_reference), do: :paid

  defp discount_targets({:coupon, _id, targets}), do: targets
  defp discount_targets(_discount_reference), do: [:monthly, :annual]

  defp promotion_code_id(code) when is_binary(code) and code != "", do: "promo_onboarding"
  defp promotion_code_id(_discount_reference), do: nil

  defp test_pid, do: Application.fetch_env!(:dhc, :onboarding_test_pid)
end
