defmodule Dhc.Stripe.PaymentPagesCheckoutSessionTotalDetailsResourceBreakdown do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionTotalDetailsResourceBreakdown
  """

  @type t :: %__MODULE__{
          discounts: [Dhc.Stripe.LineItemsDiscountAmount.t()],
          taxes: [Dhc.Stripe.LineItemsTaxAmount.t()]
        }

  defstruct [:discounts, :taxes]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discounts: [{Dhc.Stripe.LineItemsDiscountAmount, :t}],
      taxes: [{Dhc.Stripe.LineItemsTaxAmount, :t}]
    ]
  end
end
