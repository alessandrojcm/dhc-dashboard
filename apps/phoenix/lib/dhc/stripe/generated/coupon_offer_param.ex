defmodule Dhc.Stripe.CouponOfferParam do
  @moduledoc """
  Provides struct and type for a CouponOfferParam
  """

  @type t :: %__MODULE__{coupon: String.t()}

  defstruct [:coupon]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [coupon: :string]
  end
end
