defmodule Dhc.OnboardingTestStripeAdapter do
  @moduledoc false

  @behaviour Dhc.Onboarding.StripeAdapter

  @impl true
  def preview_membership(coupon_code) do
    send(test_pid(), {:preview_membership, coupon_code})
    {:ok, %{proratedPrice: %{amount: 0}}}
  end

  @impl true
  def prepare_payment(coupon_code) do
    send(test_pid(), {:prepare_payment, coupon_code})

    {:ok,
     %{
       requirement: if(coupon_code == "COMPLIMENTARY", do: :complimentary, else: :paid),
       monthly_price_id: "price_monthly_onboarding",
       annual_price_id: "price_annual_onboarding",
       promotion_code_id: if(coupon_code, do: "promo_onboarding"),
       migration?: false
     }}
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

  defp test_pid, do: Application.fetch_env!(:dhc, :onboarding_test_pid)
end
