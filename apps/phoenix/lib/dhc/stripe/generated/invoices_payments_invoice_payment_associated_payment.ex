defmodule Dhc.Stripe.InvoicesPaymentsInvoicePaymentAssociatedPayment do
  @moduledoc """
  Provides struct and type for a InvoicesPaymentsInvoicePaymentAssociatedPayment
  """

  @type t :: %__MODULE__{
          charge: Dhc.Stripe.Charge.t() | String.t() | nil,
          payment_intent: Dhc.Stripe.PaymentIntent.t() | String.t() | nil,
          payment_record: Dhc.Stripe.PaymentRecord.t() | String.t() | nil,
          type: String.t()
        }

  defstruct [:charge, :payment_intent, :payment_record, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      payment_intent: {:union, [:string, {Dhc.Stripe.PaymentIntent, :t}]},
      payment_record: {:union, [:string, {Dhc.Stripe.PaymentRecord, :t}]},
      type: {:enum, ["charge", "payment_intent", "payment_record"]}
    ]
  end
end
