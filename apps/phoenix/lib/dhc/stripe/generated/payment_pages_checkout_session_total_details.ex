defmodule Dhc.Stripe.PaymentPagesCheckoutSessionTotalDetails do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionTotalDetails
  """

  @type t :: %__MODULE__{
          amount_discount: integer,
          amount_shipping: integer | nil,
          amount_tax: integer,
          breakdown: Dhc.Stripe.PaymentPagesCheckoutSessionTotalDetailsResourceBreakdown.t() | nil
        }

  defstruct [:amount_discount, :amount_shipping, :amount_tax, :breakdown]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_discount: :integer,
      amount_shipping: :integer,
      amount_tax: :integer,
      breakdown: {Dhc.Stripe.PaymentPagesCheckoutSessionTotalDetailsResourceBreakdown, :t}
    ]
  end
end
