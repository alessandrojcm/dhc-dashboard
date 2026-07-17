defmodule Dhc.Stripe.IssuingDispute do
  @moduledoc """
  Provides struct and type for a IssuingDispute
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transactions: [Dhc.Stripe.BalanceTransaction.t()] | nil,
          created: integer,
          currency: String.t(),
          evidence: Dhc.Stripe.IssuingDisputeEvidence.t(),
          id: String.t(),
          livemode: boolean,
          loss_reason: String.t() | nil,
          metadata: map,
          object: String.t(),
          status: String.t(),
          transaction: Dhc.Stripe.IssuingTransaction.t() | String.t(),
          treasury: Dhc.Stripe.IssuingDisputeTreasury.t() | nil
        }

  defstruct [
    :amount,
    :balance_transactions,
    :created,
    :currency,
    :evidence,
    :id,
    :livemode,
    :loss_reason,
    :metadata,
    :object,
    :status,
    :transaction,
    :treasury
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transactions: [{Dhc.Stripe.BalanceTransaction, :t}],
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      evidence: {Dhc.Stripe.IssuingDisputeEvidence, :t},
      id: :string,
      livemode: :boolean,
      loss_reason:
        {:enum,
         [
           "cardholder_authentication_issuer_liability",
           "eci5_token_transaction_with_tavv",
           "excess_disputes_in_timeframe",
           "has_not_met_the_minimum_dispute_amount_requirements",
           "invalid_duplicate_dispute",
           "invalid_incorrect_amount_dispute",
           "invalid_no_authorization",
           "invalid_use_of_disputes",
           "merchandise_delivered_or_shipped",
           "merchandise_or_service_as_described",
           "not_cancelled",
           "other",
           "refund_issued",
           "submitted_beyond_allowable_time_limit",
           "transaction_3ds_required",
           "transaction_approved_after_prior_fraud_dispute",
           "transaction_authorized",
           "transaction_electronically_read",
           "transaction_qualifies_for_visa_easy_payment_service",
           "transaction_unattended"
         ]},
      metadata: :map,
      object: {:const, "issuing.dispute"},
      status: {:enum, ["expired", "lost", "submitted", "unsubmitted", "won"]},
      transaction: {:union, [:string, {Dhc.Stripe.IssuingTransaction, :t}]},
      treasury: {Dhc.Stripe.IssuingDisputeTreasury, :t}
    ]
  end
end
