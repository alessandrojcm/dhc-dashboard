defmodule Dhc.Stripe.PromotionCodesResourcePromotion do
  @moduledoc """
  Provides struct and type for a PromotionCodesResourcePromotion
  """

  @type t :: %__MODULE__{coupon: Dhc.Stripe.Coupon.t() | String.t() | nil, type: String.t()}

  defstruct [:coupon, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [coupon: {:union, [:string, {Dhc.Stripe.Coupon, :t}]}, type: {:const, "coupon"}]
  end
end
