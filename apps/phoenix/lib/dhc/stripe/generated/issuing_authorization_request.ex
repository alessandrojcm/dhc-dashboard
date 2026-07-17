defmodule Dhc.Stripe.IssuingAuthorizationRequest do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationRequest
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_details: Dhc.Stripe.IssuingAuthorizationAmountDetails.t() | nil,
          approved: boolean,
          authorization_code: String.t() | nil,
          created: integer,
          currency: String.t(),
          merchant_amount: integer,
          merchant_currency: String.t(),
          network_risk_score: integer | nil,
          reason: String.t(),
          reason_message: String.t() | nil,
          requested_at: integer | nil
        }

  defstruct [
    :amount,
    :amount_details,
    :approved,
    :authorization_code,
    :created,
    :currency,
    :merchant_amount,
    :merchant_currency,
    :network_risk_score,
    :reason,
    :reason_message,
    :requested_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_details: {Dhc.Stripe.IssuingAuthorizationAmountDetails, :t},
      approved: :boolean,
      authorization_code: :string,
      created: {:integer, "unix-time"},
      currency: :string,
      merchant_amount: :integer,
      merchant_currency: :string,
      network_risk_score: :integer,
      reason:
        {:enum,
         [
           "account_disabled",
           "card_active",
           "card_canceled",
           "card_expired",
           "card_inactive",
           "cardholder_blocked",
           "cardholder_inactive",
           "cardholder_verification_required",
           "insecure_authorization_method",
           "insufficient_funds",
           "network_fallback",
           "not_allowed",
           "pin_blocked",
           "spending_controls",
           "suspected_fraud",
           "verification_failed",
           "webhook_approved",
           "webhook_declined",
           "webhook_error",
           "webhook_timeout"
         ]},
      reason_message: :string,
      requested_at: {:integer, "unix-time"}
    ]
  end
end
