defmodule Dhc.Stripe.ApplicationFee do
  @moduledoc """
  Provides struct and type for a ApplicationFee
  """

  @type t :: %__MODULE__{
          account: Dhc.Stripe.Account.t() | String.t(),
          amount: integer,
          amount_refunded: integer,
          application: Dhc.Stripe.Application.t() | String.t(),
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          charge: Dhc.Stripe.Charge.t() | String.t(),
          created: integer,
          currency: String.t(),
          fee_source: Dhc.Stripe.PlatformEarningFeeSource.t() | nil,
          id: String.t(),
          livemode: boolean,
          object: String.t(),
          originating_transaction: Dhc.Stripe.Charge.t() | String.t() | nil,
          refunded: boolean,
          refunds: Dhc.Stripe.FeeRefundList.t()
        }

  defstruct [
    :account,
    :amount,
    :amount_refunded,
    :application,
    :balance_transaction,
    :charge,
    :created,
    :currency,
    :fee_source,
    :id,
    :livemode,
    :object,
    :originating_transaction,
    :refunded,
    :refunds
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      amount: :integer,
      amount_refunded: :integer,
      application: {:union, [:string, {Dhc.Stripe.Application, :t}]},
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      fee_source: {Dhc.Stripe.PlatformEarningFeeSource, :t},
      id: :string,
      livemode: :boolean,
      object: {:const, "application_fee"},
      originating_transaction: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      refunded: :boolean,
      refunds: {Dhc.Stripe.FeeRefundList, :t}
    ]
  end
end
