defmodule Dhc.Stripe.CreditNoteLineItem do
  @moduledoc """
  Provides struct and type for a CreditNoteLineItem
  """

  @type t :: %__MODULE__{
          amount: integer,
          description: String.t() | nil,
          discount_amount: integer,
          discount_amounts: [Dhc.Stripe.DiscountsResourceDiscountAmount.t()],
          id: String.t(),
          invoice_line_item: String.t() | nil,
          livemode: boolean,
          metadata: map | nil,
          object: String.t(),
          pretax_credit_amounts: [Dhc.Stripe.CreditNotesPretaxCreditAmount.t()],
          quantity: integer | nil,
          tax_rates: [Dhc.Stripe.TaxRate.t()],
          taxes: [Dhc.Stripe.BillingBillResourceInvoicingTaxesTax.t()] | nil,
          type: String.t(),
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil
        }

  defstruct [
    :amount,
    :description,
    :discount_amount,
    :discount_amounts,
    :id,
    :invoice_line_item,
    :livemode,
    :metadata,
    :object,
    :pretax_credit_amounts,
    :quantity,
    :tax_rates,
    :taxes,
    :type,
    :unit_amount,
    :unit_amount_decimal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      description: :string,
      discount_amount: :integer,
      discount_amounts: [{Dhc.Stripe.DiscountsResourceDiscountAmount, :t}],
      id: :string,
      invoice_line_item: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "credit_note_line_item"},
      pretax_credit_amounts: [{Dhc.Stripe.CreditNotesPretaxCreditAmount, :t}],
      quantity: :integer,
      tax_rates: [{Dhc.Stripe.TaxRate, :t}],
      taxes: [{Dhc.Stripe.BillingBillResourceInvoicingTaxesTax, :t}],
      type: {:enum, ["custom_line_item", "invoice_line_item"]},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
