defmodule Dhc.Stripe.CouponAppliesTo do
  @moduledoc """
  Provides struct and type for a CouponAppliesTo
  """

  @type t :: %__MODULE__{products: [String.t()]}

  defstruct [:products]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [products: [:string]]
  end
end
