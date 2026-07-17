defmodule Dhc.Stripe.IssuingTransaction do
  @moduledoc """
  Provides struct and type for a IssuingTransaction
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_details: Dhc.Stripe.IssuingTransactionAmountDetails.t() | nil,
          authorization: Dhc.Stripe.IssuingAuthorization.t() | String.t() | nil,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          card: Dhc.Stripe.IssuingCard.t() | String.t(),
          cardholder: Dhc.Stripe.IssuingCardholder.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          dispute: Dhc.Stripe.IssuingDispute.t() | String.t() | nil,
          id: String.t(),
          livemode: boolean,
          merchant_amount: integer,
          merchant_currency: String.t(),
          merchant_data: Dhc.Stripe.IssuingAuthorizationMerchantData.t(),
          metadata: map,
          network_data: Dhc.Stripe.IssuingTransactionNetworkData.t() | nil,
          object: String.t(),
          purchase_details: Dhc.Stripe.IssuingTransactionPurchaseDetails.t() | nil,
          token: Dhc.Stripe.IssuingToken.t() | String.t() | nil,
          treasury: Dhc.Stripe.IssuingTransactionTreasury.t() | nil,
          type: String.t(),
          wallet: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_details,
    :authorization,
    :balance_transaction,
    :card,
    :cardholder,
    :created,
    :currency,
    :dispute,
    :id,
    :livemode,
    :merchant_amount,
    :merchant_currency,
    :merchant_data,
    :metadata,
    :network_data,
    :object,
    :purchase_details,
    :token,
    :treasury,
    :type,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_details: {Dhc.Stripe.IssuingTransactionAmountDetails, :t},
      authorization: {:union, [:string, {Dhc.Stripe.IssuingAuthorization, :t}]},
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      card: {:union, [:string, {Dhc.Stripe.IssuingCard, :t}]},
      cardholder: {:union, [:string, {Dhc.Stripe.IssuingCardholder, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      dispute: {:union, [:string, {Dhc.Stripe.IssuingDispute, :t}]},
      id: :string,
      livemode: :boolean,
      merchant_amount: :integer,
      merchant_currency: {:string, "currency"},
      merchant_data: {Dhc.Stripe.IssuingAuthorizationMerchantData, :t},
      metadata: :map,
      network_data: {Dhc.Stripe.IssuingTransactionNetworkData, :t},
      object: {:const, "issuing.transaction"},
      purchase_details: {Dhc.Stripe.IssuingTransactionPurchaseDetails, :t},
      token: {:union, [:string, {Dhc.Stripe.IssuingToken, :t}]},
      treasury: {Dhc.Stripe.IssuingTransactionTreasury, :t},
      type: {:enum, ["capture", "refund"]},
      wallet: {:enum, ["apple_pay", "google_pay", "samsung_pay"]}
    ]
  end
end
