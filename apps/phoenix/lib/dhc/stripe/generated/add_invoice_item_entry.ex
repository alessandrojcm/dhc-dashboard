defmodule Dhc.Stripe.AddInvoiceItemEntry do
  @moduledoc """
  Provides struct and types for a AddInvoiceItemEntry
  """

  @type t :: %__MODULE__{
          discountable: boolean | nil,
          discounts: [Dhc.Stripe.DiscountsDataParam.t()] | nil,
          metadata: map | nil,
          period: Dhc.Stripe.InvoiceItemPeriod.t() | nil,
          price: String.t() | nil,
          price_data: Dhc.Stripe.OneTimePriceDataWithNegativeAmounts.t() | nil,
          quantity: integer | nil,
          tax_rates: String.t() | [String.t()] | nil
        }

  defstruct [
    :discountable,
    :discounts,
    :metadata,
    :period,
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
      discountable: :boolean,
      discounts: [{Dhc.Stripe.DiscountsDataParam, :t}],
      metadata: :map,
      period: {Dhc.Stripe.InvoiceItemPeriod, :t},
      price: :string,
      price_data: {Dhc.Stripe.OneTimePriceDataWithNegativeAmounts, :t},
      quantity: :integer,
      tax_rates: {:union, [{:const, ""}, [:string]]}
    ]
  end
end
