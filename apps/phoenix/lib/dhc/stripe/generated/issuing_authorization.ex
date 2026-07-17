defmodule Dhc.Stripe.IssuingAuthorization do
  @moduledoc """
  Provides struct and type for a IssuingAuthorization
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_details: Dhc.Stripe.IssuingAuthorizationAmountDetails.t() | nil,
          approved: boolean,
          authorization_method: String.t(),
          balance_transactions: [Dhc.Stripe.BalanceTransaction.t()],
          card: Dhc.Stripe.IssuingCard.t(),
          card_presence: String.t() | nil,
          cardholder: Dhc.Stripe.IssuingCardholder.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          fleet: Dhc.Stripe.IssuingAuthorizationFleetData.t() | nil,
          fraud_challenges: [Dhc.Stripe.IssuingAuthorizationFraudChallenge.t()] | nil,
          fuel: Dhc.Stripe.IssuingAuthorizationFuelData.t() | nil,
          id: String.t(),
          livemode: boolean,
          merchant_amount: integer,
          merchant_currency: String.t(),
          merchant_data: Dhc.Stripe.IssuingAuthorizationMerchantData.t(),
          metadata: map,
          network_data: Dhc.Stripe.IssuingAuthorizationNetworkData.t() | nil,
          object: String.t(),
          pending_request: Dhc.Stripe.IssuingAuthorizationPendingRequest.t() | nil,
          request_history: [Dhc.Stripe.IssuingAuthorizationRequest.t()],
          status: String.t(),
          token: Dhc.Stripe.IssuingToken.t() | String.t() | nil,
          transactions: [Dhc.Stripe.IssuingTransaction.t()],
          treasury: Dhc.Stripe.IssuingAuthorizationTreasury.t() | nil,
          verification_data: Dhc.Stripe.IssuingAuthorizationVerificationData.t(),
          verified_by_fraud_challenge: boolean | nil,
          wallet: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_details,
    :approved,
    :authorization_method,
    :balance_transactions,
    :card,
    :card_presence,
    :cardholder,
    :created,
    :currency,
    :fleet,
    :fraud_challenges,
    :fuel,
    :id,
    :livemode,
    :merchant_amount,
    :merchant_currency,
    :merchant_data,
    :metadata,
    :network_data,
    :object,
    :pending_request,
    :request_history,
    :status,
    :token,
    :transactions,
    :treasury,
    :verification_data,
    :verified_by_fraud_challenge,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_details: {Dhc.Stripe.IssuingAuthorizationAmountDetails, :t},
      approved: :boolean,
      authorization_method: {:enum, ["chip", "contactless", "keyed_in", "online", "swipe"]},
      balance_transactions: [{Dhc.Stripe.BalanceTransaction, :t}],
      card: {Dhc.Stripe.IssuingCard, :t},
      card_presence: {:enum, ["not_present", "present"]},
      cardholder: {:union, [:string, {Dhc.Stripe.IssuingCardholder, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      fleet: {Dhc.Stripe.IssuingAuthorizationFleetData, :t},
      fraud_challenges: [{Dhc.Stripe.IssuingAuthorizationFraudChallenge, :t}],
      fuel: {Dhc.Stripe.IssuingAuthorizationFuelData, :t},
      id: :string,
      livemode: :boolean,
      merchant_amount: :integer,
      merchant_currency: {:string, "currency"},
      merchant_data: {Dhc.Stripe.IssuingAuthorizationMerchantData, :t},
      metadata: :map,
      network_data: {Dhc.Stripe.IssuingAuthorizationNetworkData, :t},
      object: {:const, "issuing.authorization"},
      pending_request: {Dhc.Stripe.IssuingAuthorizationPendingRequest, :t},
      request_history: [{Dhc.Stripe.IssuingAuthorizationRequest, :t}],
      status: {:enum, ["closed", "expired", "pending", "reversed"]},
      token: {:union, [:string, {Dhc.Stripe.IssuingToken, :t}]},
      transactions: [{Dhc.Stripe.IssuingTransaction, :t}],
      treasury: {Dhc.Stripe.IssuingAuthorizationTreasury, :t},
      verification_data: {Dhc.Stripe.IssuingAuthorizationVerificationData, :t},
      verified_by_fraud_challenge: :boolean,
      wallet: :string
    ]
  end
end
