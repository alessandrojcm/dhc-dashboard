defmodule Dhc.Stripe.PaymentRecord do
  @moduledoc """
  Provides struct and type for a PaymentRecord
  """

  @type t :: %__MODULE__{
          amount: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_authorized: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_canceled: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_failed: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_guaranteed: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_refunded: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          amount_requested: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount.t(),
          application: String.t() | nil,
          created: integer,
          customer_details:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceCustomerDetails.t() | nil,
          customer_presence: String.t() | nil,
          description: String.t() | nil,
          id: String.t(),
          latest_payment_attempt_record: String.t() | nil,
          livemode: boolean,
          metadata: map,
          object: String.t(),
          payment_method_details:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodDetails.t() | nil,
          processor_details:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetails.t(),
          reported_by: String.t(),
          shipping_details:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceShippingDetails.t() | nil
        }

  defstruct [
    :amount,
    :amount_authorized,
    :amount_canceled,
    :amount_failed,
    :amount_guaranteed,
    :amount_refunded,
    :amount_requested,
    :application,
    :created,
    :customer_details,
    :customer_presence,
    :description,
    :id,
    :latest_payment_attempt_record,
    :livemode,
    :metadata,
    :object,
    :payment_method_details,
    :processor_details,
    :reported_by,
    :shipping_details
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_authorized: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_canceled: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_failed: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_guaranteed: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_refunded: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      amount_requested: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount, :t},
      application: :string,
      created: {:integer, "unix-time"},
      customer_details: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceCustomerDetails, :t},
      customer_presence: {:enum, ["off_session", "on_session"]},
      description: :string,
      id: :string,
      latest_payment_attempt_record: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "payment_record"},
      payment_method_details:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodDetails, :t},
      processor_details:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetails, :t},
      reported_by: {:enum, ["self", "stripe"]},
      shipping_details: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceShippingDetails, :t}
    ]
  end
end
