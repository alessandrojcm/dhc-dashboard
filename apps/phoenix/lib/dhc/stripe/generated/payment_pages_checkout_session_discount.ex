defmodule Dhc.Stripe.PaymentPagesCheckoutSessionDiscount do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionDiscount
  """

  @type t :: %__MODULE__{
          coupon: Dhc.Stripe.Coupon.t() | String.t() | nil,
          promotion_code: Dhc.Stripe.PromotionCode.t() | String.t() | nil
        }

  defstruct [:coupon, :promotion_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      coupon: {:union, [:string, {Dhc.Stripe.Coupon, :t}]},
      promotion_code: {:union, [:string, {Dhc.Stripe.PromotionCode, :t}]}
    ]
  end
end
