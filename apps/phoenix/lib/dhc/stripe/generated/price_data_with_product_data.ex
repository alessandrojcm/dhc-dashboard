defmodule Dhc.Stripe.PriceDataWithProductData do
  @moduledoc """
  Provides struct and type for a PriceDataWithProductData
  """

  @type t :: %__MODULE__{
          currency: String.t(),
          product: String.t() | nil,
          product_data: Dhc.Stripe.ProductData.t() | nil,
          recurring: Dhc.Stripe.RecurringAdhoc.t() | nil,
          tax_behavior: String.t() | nil,
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil
        }

  defstruct [
    :currency,
    :product,
    :product_data,
    :recurring,
    :tax_behavior,
    :unit_amount,
    :unit_amount_decimal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      currency: {:string, "currency"},
      product: :string,
      product_data: {Dhc.Stripe.ProductData, :t},
      recurring: {Dhc.Stripe.RecurringAdhoc, :t},
      tax_behavior: {:enum, ["exclusive", "inclusive", "unspecified"]},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
