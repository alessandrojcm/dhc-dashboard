defmodule Dhc.Stripe.SubscriptionScheduleAddInvoiceItem do
  @moduledoc """
  Provides struct and type for a SubscriptionScheduleAddInvoiceItem
  """

  @type t :: %__MODULE__{
          discountable: boolean | nil,
          discounts: [Dhc.Stripe.DiscountsResourceStackableDiscountWithDiscountEnd.t()],
          metadata: map | nil,
          period: Dhc.Stripe.SubscriptionScheduleAddInvoiceItemPeriod.t(),
          price: Dhc.Stripe.DeletedPrice.t() | Dhc.Stripe.Price.t() | String.t(),
          quantity: integer | nil,
          tax_rates: [Dhc.Stripe.TaxRate.t()] | nil
        }

  defstruct [:discountable, :discounts, :metadata, :period, :price, :quantity, :tax_rates]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discountable: :boolean,
      discounts: [{Dhc.Stripe.DiscountsResourceStackableDiscountWithDiscountEnd, :t}],
      metadata: :map,
      period: {Dhc.Stripe.SubscriptionScheduleAddInvoiceItemPeriod, :t},
      price: {:union, [:string, {Dhc.Stripe.DeletedPrice, :t}, {Dhc.Stripe.Price, :t}]},
      quantity: :integer,
      tax_rates: [{Dhc.Stripe.TaxRate, :t}]
    ]
  end
end
