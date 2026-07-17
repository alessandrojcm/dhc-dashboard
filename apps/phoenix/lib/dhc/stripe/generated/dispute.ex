defmodule Dhc.Stripe.Dispute do
  @moduledoc """
  Provides struct and type for a Dispute
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transactions: [Dhc.Stripe.BalanceTransaction.t()],
          charge: Dhc.Stripe.Charge.t() | String.t(),
          created: integer,
          currency: String.t(),
          enhanced_eligibility_types: [String.t()],
          evidence: Dhc.Stripe.DisputeEvidence.t(),
          evidence_details: Dhc.Stripe.DisputeEvidenceDetails.t(),
          id: String.t(),
          is_charge_refundable: boolean,
          livemode: boolean,
          metadata: map,
          object: String.t(),
          payment_intent: Dhc.Stripe.PaymentIntent.t() | String.t() | nil,
          payment_method_details: Dhc.Stripe.DisputePaymentMethodDetails.t() | nil,
          reason: String.t(),
          status: String.t()
        }

  defstruct [
    :amount,
    :balance_transactions,
    :charge,
    :created,
    :currency,
    :enhanced_eligibility_types,
    :evidence,
    :evidence_details,
    :id,
    :is_charge_refundable,
    :livemode,
    :metadata,
    :object,
    :payment_intent,
    :payment_method_details,
    :reason,
    :status
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transactions: [{Dhc.Stripe.BalanceTransaction, :t}],
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      enhanced_eligibility_types: [
        enum: ["mastercard_compliance", "visa_compelling_evidence_3", "visa_compliance"]
      ],
      evidence: {Dhc.Stripe.DisputeEvidence, :t},
      evidence_details: {Dhc.Stripe.DisputeEvidenceDetails, :t},
      id: :string,
      is_charge_refundable: :boolean,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "dispute"},
      payment_intent: {:union, [:string, {Dhc.Stripe.PaymentIntent, :t}]},
      payment_method_details: {Dhc.Stripe.DisputePaymentMethodDetails, :t},
      reason: :string,
      status:
        {:enum,
         [
           "lost",
           "needs_response",
           "prevented",
           "under_review",
           "warning_closed",
           "warning_needs_response",
           "warning_under_review",
           "won"
         ]}
    ]
  end
end
