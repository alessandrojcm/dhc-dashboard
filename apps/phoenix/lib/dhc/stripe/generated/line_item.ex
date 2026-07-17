defmodule Dhc.Stripe.LineItem do
  @moduledoc """
  Provides struct and type for a LineItem
  """

  @type t :: %__MODULE__{
          amount: integer,
          currency: String.t(),
          description: String.t() | nil,
          discount_amounts: [Dhc.Stripe.DiscountsResourceDiscountAmount.t()] | nil,
          discountable: boolean,
          discounts: [Dhc.Stripe.Discount.t() | String.t()],
          id: String.t(),
          invoice: String.t() | nil,
          livemode: boolean,
          metadata: map,
          object: String.t(),
          parent:
            Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemParent.t() | nil,
          period: Dhc.Stripe.InvoiceLineItemPeriod.t(),
          pretax_credit_amounts: [Dhc.Stripe.InvoicesResourcePretaxCreditAmount.t()] | nil,
          pricing: Dhc.Stripe.BillingBillResourceInvoicingPricingPricing.t() | nil,
          quantity: integer | nil,
          quantity_decimal: String.t() | nil,
          subscription: Dhc.Stripe.Subscription.t() | String.t() | nil,
          subtotal: integer,
          taxes: [Dhc.Stripe.BillingBillResourceInvoicingTaxesTax.t()] | nil
        }

  defstruct [
    :amount,
    :currency,
    :description,
    :discount_amounts,
    :discountable,
    :discounts,
    :id,
    :invoice,
    :livemode,
    :metadata,
    :object,
    :parent,
    :period,
    :pretax_credit_amounts,
    :pricing,
    :quantity,
    :quantity_decimal,
    :subscription,
    :subtotal,
    :taxes
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: {:string, "currency"},
      description: :string,
      discount_amounts: [{Dhc.Stripe.DiscountsResourceDiscountAmount, :t}],
      discountable: :boolean,
      discounts: [union: [:string, {Dhc.Stripe.Discount, :t}]],
      id: :string,
      invoice: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "line_item"},
      parent: {Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemParent, :t},
      period: {Dhc.Stripe.InvoiceLineItemPeriod, :t},
      pretax_credit_amounts: [{Dhc.Stripe.InvoicesResourcePretaxCreditAmount, :t}],
      pricing: {Dhc.Stripe.BillingBillResourceInvoicingPricingPricing, :t},
      quantity: :integer,
      quantity_decimal: {:string, "decimal"},
      subscription: {:union, [:string, {Dhc.Stripe.Subscription, :t}]},
      subtotal: :integer,
      taxes: [{Dhc.Stripe.BillingBillResourceInvoicingTaxesTax, :t}]
    ]
  end
end
