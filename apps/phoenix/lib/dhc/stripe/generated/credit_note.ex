defmodule Dhc.Stripe.CreditNote do
  @moduledoc """
  Provides struct and type for a CreditNote
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_shipping: integer,
          created: integer,
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t(),
          customer_account: String.t() | nil,
          customer_balance_transaction:
            Dhc.Stripe.CustomerBalanceTransaction.t() | String.t() | nil,
          discount_amount: integer,
          discount_amounts: [Dhc.Stripe.DiscountsResourceDiscountAmount.t()],
          effective_at: integer | nil,
          id: String.t(),
          invoice: Dhc.Stripe.Invoice.t() | String.t(),
          lines: Dhc.Stripe.CreditNoteLinesList.t(),
          livemode: boolean,
          memo: String.t() | nil,
          metadata: map | nil,
          number: String.t(),
          object: String.t(),
          out_of_band_amount: integer | nil,
          pdf: String.t(),
          post_payment_amount: integer,
          pre_payment_amount: integer,
          pretax_credit_amounts: [Dhc.Stripe.CreditNotesPretaxCreditAmount.t()],
          reason: String.t() | nil,
          refunds: [Dhc.Stripe.CreditNoteRefund.t()],
          shipping_cost: Dhc.Stripe.InvoicesResourceShippingCost.t() | nil,
          status: String.t(),
          subtotal: integer,
          subtotal_excluding_tax: integer | nil,
          total: integer,
          total_excluding_tax: integer | nil,
          total_taxes: [Dhc.Stripe.BillingBillResourceInvoicingTaxesTax.t()] | nil,
          type: String.t(),
          voided_at: integer | nil
        }

  defstruct [
    :amount,
    :amount_shipping,
    :created,
    :currency,
    :customer,
    :customer_account,
    :customer_balance_transaction,
    :discount_amount,
    :discount_amounts,
    :effective_at,
    :id,
    :invoice,
    :lines,
    :livemode,
    :memo,
    :metadata,
    :number,
    :object,
    :out_of_band_amount,
    :pdf,
    :post_payment_amount,
    :pre_payment_amount,
    :pretax_credit_amounts,
    :reason,
    :refunds,
    :shipping_cost,
    :status,
    :subtotal,
    :subtotal_excluding_tax,
    :total,
    :total_excluding_tax,
    :total_taxes,
    :type,
    :voided_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_shipping: :integer,
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      customer_balance_transaction:
        {:union, [:string, {Dhc.Stripe.CustomerBalanceTransaction, :t}]},
      discount_amount: :integer,
      discount_amounts: [{Dhc.Stripe.DiscountsResourceDiscountAmount, :t}],
      effective_at: {:integer, "unix-time"},
      id: :string,
      invoice: {:union, [:string, {Dhc.Stripe.Invoice, :t}]},
      lines: {Dhc.Stripe.CreditNoteLinesList, :t},
      livemode: :boolean,
      memo: :string,
      metadata: :map,
      number: :string,
      object: {:const, "credit_note"},
      out_of_band_amount: :integer,
      pdf: :string,
      post_payment_amount: :integer,
      pre_payment_amount: :integer,
      pretax_credit_amounts: [{Dhc.Stripe.CreditNotesPretaxCreditAmount, :t}],
      reason: {:enum, ["duplicate", "fraudulent", "order_change", "product_unsatisfactory"]},
      refunds: [{Dhc.Stripe.CreditNoteRefund, :t}],
      shipping_cost: {Dhc.Stripe.InvoicesResourceShippingCost, :t},
      status: {:enum, ["issued", "void"]},
      subtotal: :integer,
      subtotal_excluding_tax: :integer,
      total: :integer,
      total_excluding_tax: :integer,
      total_taxes: [{Dhc.Stripe.BillingBillResourceInvoicingTaxesTax, :t}],
      type: {:enum, ["mixed", "post_payment", "pre_payment"]},
      voided_at: {:integer, "unix-time"}
    ]
  end
end
