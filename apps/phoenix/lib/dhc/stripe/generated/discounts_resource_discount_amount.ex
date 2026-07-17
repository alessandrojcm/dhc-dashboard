defmodule Dhc.Stripe.DiscountsResourceDiscountAmount do
  @moduledoc """
  Provides struct and type for a DiscountsResourceDiscountAmount
  """

  @type t :: %__MODULE__{
          amount: integer,
          discount: Dhc.Stripe.DeletedDiscount.t() | Dhc.Stripe.Discount.t() | String.t()
        }

  defstruct [:amount, :discount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      discount: {:union, [:string, {Dhc.Stripe.DeletedDiscount, :t}, {Dhc.Stripe.Discount, :t}]}
    ]
  end
end
