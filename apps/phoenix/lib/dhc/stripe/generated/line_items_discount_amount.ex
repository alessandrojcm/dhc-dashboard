defmodule Dhc.Stripe.LineItemsDiscountAmount do
  @moduledoc """
  Provides struct and type for a LineItemsDiscountAmount
  """

  @type t :: %__MODULE__{amount: integer, discount: Dhc.Stripe.Discount.t()}

  defstruct [:amount, :discount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, discount: {Dhc.Stripe.Discount, :t}]
  end
end
