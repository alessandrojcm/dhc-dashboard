defmodule Dhc.Stripe.Refund do
  @moduledoc """
  Provides struct and type for a Refund
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          charge: Dhc.Stripe.Charge.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          customer_account: String.t() | nil,
          description: String.t() | nil,
          destination_details: Dhc.Stripe.RefundDestinationDetails.t() | nil,
          failure_balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          failure_reason: String.t() | nil,
          id: String.t(),
          instructions_email: String.t() | nil,
          metadata: map | nil,
          next_action: Dhc.Stripe.RefundNextAction.t() | nil,
          object: String.t(),
          payment_intent: Dhc.Stripe.PaymentIntent.t() | String.t() | nil,
          payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          pending_reason: String.t() | nil,
          presentment_details: Dhc.Stripe.PaymentFlowsPaymentIntentPresentmentDetails.t() | nil,
          reason: String.t() | nil,
          receipt_number: String.t() | nil,
          source_transfer_reversal: Dhc.Stripe.TransferReversal.t() | String.t() | nil,
          status: String.t() | nil,
          transfer_reversal: Dhc.Stripe.TransferReversal.t() | String.t() | nil
        }

  defstruct [
    :amount,
    :balance_transaction,
    :charge,
    :created,
    :currency,
    :customer,
    :customer_account,
    :description,
    :destination_details,
    :failure_balance_transaction,
    :failure_reason,
    :id,
    :instructions_email,
    :metadata,
    :next_action,
    :object,
    :payment_intent,
    :payment_method,
    :pending_reason,
    :presentment_details,
    :reason,
    :receipt_number,
    :source_transfer_reversal,
    :status,
    :transfer_reversal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      description: :string,
      destination_details: {Dhc.Stripe.RefundDestinationDetails, :t},
      failure_balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      failure_reason: :string,
      id: :string,
      instructions_email: :string,
      metadata: :map,
      next_action: {Dhc.Stripe.RefundNextAction, :t},
      object: {:const, "refund"},
      payment_intent: {:union, [:string, {Dhc.Stripe.PaymentIntent, :t}]},
      payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      pending_reason: {:enum, ["charge_pending", "insufficient_funds", "processing"]},
      presentment_details: {Dhc.Stripe.PaymentFlowsPaymentIntentPresentmentDetails, :t},
      reason:
        {:enum, ["duplicate", "expired_uncaptured_charge", "fraudulent", "requested_by_customer"]},
      receipt_number: :string,
      source_transfer_reversal: {:union, [:string, {Dhc.Stripe.TransferReversal, :t}]},
      status: :string,
      transfer_reversal: {:union, [:string, {Dhc.Stripe.TransferReversal, :t}]}
    ]
  end
end
