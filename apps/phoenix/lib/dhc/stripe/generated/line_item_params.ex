defmodule Dhc.Stripe.LineItemParams do
  @moduledoc """
  Provides struct and type for a LineItemParams
  """

  @type t :: %__MODULE__{
          adjustable_quantity: Dhc.Stripe.AdjustableQuantityParams.t() | nil,
          dynamic_tax_rates: [String.t()] | nil,
          metadata: map | nil,
          price: String.t() | nil,
          price_data: Dhc.Stripe.PriceDataWithProductData.t() | nil,
          quantity: integer | nil,
          tax_rates: [String.t()] | nil
        }

  defstruct [
    :adjustable_quantity,
    :dynamic_tax_rates,
    :metadata,
    :price,
    :price_data,
    :quantity,
    :tax_rates
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity: {Dhc.Stripe.AdjustableQuantityParams, :t},
      dynamic_tax_rates: [:string],
      metadata: :map,
      price: :string,
      price_data: {Dhc.Stripe.PriceDataWithProductData, :t},
      quantity: :integer,
      tax_rates: [:string]
    ]
  end
end
