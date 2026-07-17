defmodule Dhc.Stripe.InvoiceItemPreviewParams do
  @moduledoc """
  Provides struct and type for a InvoiceItemPreviewParams
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          currency: String.t() | nil,
          description: String.t() | nil,
          discountable: boolean | nil,
          discounts: String.t() | [map] | nil,
          invoiceitem: String.t() | nil,
          metadata: map | String.t() | nil,
          period: Dhc.Stripe.Period.t() | nil,
          price: String.t() | nil,
          price_data: Dhc.Stripe.OneTimePriceData.t() | nil,
          quantity: integer | nil,
          quantity_decimal: String.t() | nil,
          tax_behavior: String.t() | nil,
          tax_code: String.t() | nil,
          tax_rates: String.t() | [String.t()] | nil,
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil
        }

  defstruct [
    :amount,
    :currency,
    :description,
    :discountable,
    :discounts,
    :invoiceitem,
    :metadata,
    :period,
    :price,
    :price_data,
    :quantity,
    :quantity_decimal,
    :tax_behavior,
    :tax_code,
    :tax_rates,
    :unit_amount,
    :unit_amount_decimal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: {:string, "currency"},
      description: :string,
      discountable: :boolean,
      discounts: {:union, [{:const, ""}, [:map]]},
      invoiceitem: :string,
      metadata: {:union, [:map, const: ""]},
      period: {Dhc.Stripe.Period, :t},
      price: :string,
      price_data: {Dhc.Stripe.OneTimePriceData, :t},
      quantity: :integer,
      quantity_decimal: {:string, "decimal"},
      tax_behavior: {:enum, ["exclusive", "inclusive", "unspecified"]},
      tax_code: {:union, [:string, const: ""]},
      tax_rates: {:union, [{:const, ""}, [:string]]},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
