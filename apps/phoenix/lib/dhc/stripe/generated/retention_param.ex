defmodule Dhc.Stripe.RetentionParam do
  @moduledoc """
  Provides struct and type for a RetentionParam
  """

  @type t :: %__MODULE__{coupon_offer: Dhc.Stripe.CouponOfferParam.t(), type: String.t()}

  defstruct [:coupon_offer, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [coupon_offer: {Dhc.Stripe.CouponOfferParam, :t}, type: {:const, "coupon_offer"}]
  end
end
