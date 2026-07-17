defmodule Dhc.Stripe.CustomerCashBalanceTransaction do
  @moduledoc """
  Provides struct and type for a CustomerCashBalanceTransaction
  """

  @type t :: %__MODULE__{
          adjusted_for_overdraft:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAdjustedForOverdraft.t()
            | nil,
          applied_to_payment:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAppliedToPaymentTransaction.t()
            | nil,
          created: integer,
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | String.t(),
          customer_account: String.t() | nil,
          ending_balance: integer,
          funded:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransaction.t()
            | nil,
          id: String.t(),
          livemode: boolean,
          net_amount: integer,
          object: String.t(),
          refunded_from_payment:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceRefundedFromPaymentTransaction.t()
            | nil,
          transferred_to_balance:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceTransferredToBalance.t()
            | nil,
          type: String.t(),
          unapplied_from_payment:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceUnappliedFromPaymentTransaction.t()
            | nil
        }

  defstruct [
    :adjusted_for_overdraft,
    :applied_to_payment,
    :created,
    :currency,
    :customer,
    :customer_account,
    :ending_balance,
    :funded,
    :id,
    :livemode,
    :net_amount,
    :object,
    :refunded_from_payment,
    :transferred_to_balance,
    :type,
    :unapplied_from_payment
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjusted_for_overdraft:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAdjustedForOverdraft, :t},
      applied_to_payment:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAppliedToPaymentTransaction,
         :t},
      created: {:integer, "unix-time"},
      currency: :string,
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}]},
      customer_account: :string,
      ending_balance: :integer,
      funded:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransaction, :t},
      id: :string,
      livemode: :boolean,
      net_amount: :integer,
      object: {:const, "customer_cash_balance_transaction"},
      refunded_from_payment:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceRefundedFromPaymentTransaction,
         :t},
      transferred_to_balance:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceTransferredToBalance, :t},
      type:
        {:enum,
         [
           "adjusted_for_overdraft",
           "applied_to_payment",
           "funded",
           "funding_reversed",
           "refunded_from_payment",
           "return_canceled",
           "return_initiated",
           "transferred_to_balance",
           "unapplied_from_payment"
         ]},
      unapplied_from_payment:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceUnappliedFromPaymentTransaction,
         :t}
    ]
  end
end
