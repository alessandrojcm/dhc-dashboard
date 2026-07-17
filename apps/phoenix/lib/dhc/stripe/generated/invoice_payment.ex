defmodule Dhc.Stripe.InvoicePayment do
  @moduledoc """
  Provides struct and type for a InvoicePayment
  """

  @type t :: %__MODULE__{
          amount_paid: integer | nil,
          amount_requested: integer,
          created: integer,
          currency: String.t(),
          id: String.t(),
          invoice: Dhc.Stripe.DeletedInvoice.t() | Dhc.Stripe.Invoice.t() | String.t(),
          is_default: boolean,
          livemode: boolean,
          object: String.t(),
          payment: Dhc.Stripe.InvoicesPaymentsInvoicePaymentAssociatedPayment.t(),
          status: String.t(),
          status_transitions: Dhc.Stripe.InvoicesPaymentsInvoicePaymentStatusTransitions.t()
        }

  defstruct [
    :amount_paid,
    :amount_requested,
    :created,
    :currency,
    :id,
    :invoice,
    :is_default,
    :livemode,
    :object,
    :payment,
    :status,
    :status_transitions
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_paid: :integer,
      amount_requested: :integer,
      created: {:integer, "unix-time"},
      currency: :string,
      id: :string,
      invoice: {:union, [:string, {Dhc.Stripe.DeletedInvoice, :t}, {Dhc.Stripe.Invoice, :t}]},
      is_default: :boolean,
      livemode: :boolean,
      object: {:const, "invoice_payment"},
      payment: {Dhc.Stripe.InvoicesPaymentsInvoicePaymentAssociatedPayment, :t},
      status: :string,
      status_transitions: {Dhc.Stripe.InvoicesPaymentsInvoicePaymentStatusTransitions, :t}
    ]
  end
end
