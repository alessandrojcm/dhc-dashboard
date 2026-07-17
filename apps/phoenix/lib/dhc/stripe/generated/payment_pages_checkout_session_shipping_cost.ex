defmodule Dhc.Stripe.PaymentPagesCheckoutSessionShippingCost do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionShippingCost
  """

  @type t :: %__MODULE__{
          amount_subtotal: integer,
          amount_tax: integer,
          amount_total: integer,
          shipping_rate: Dhc.Stripe.ShippingRate.t() | String.t() | nil,
          taxes: [Dhc.Stripe.LineItemsTaxAmount.t()] | nil
        }

  defstruct [:amount_subtotal, :amount_tax, :amount_total, :shipping_rate, :taxes]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_subtotal: :integer,
      amount_tax: :integer,
      amount_total: :integer,
      shipping_rate: {:union, [:string, {Dhc.Stripe.ShippingRate, :t}]},
      taxes: [{Dhc.Stripe.LineItemsTaxAmount, :t}]
    ]
  end
end
