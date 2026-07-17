defmodule Dhc.Stripe.Payout do
  @moduledoc """
  Provides struct and type for a Payout
  """

  @type t :: %__MODULE__{
          amount: integer,
          application_fee: Dhc.Stripe.ApplicationFee.t() | String.t() | nil,
          application_fee_amount: integer | nil,
          arrival_date: integer,
          automatic: boolean,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          description: String.t() | nil,
          destination:
            Dhc.Stripe.BankAccount.t()
            | Dhc.Stripe.Card.t()
            | Dhc.Stripe.DeletedBankAccount.t()
            | Dhc.Stripe.DeletedCard.t()
            | String.t()
            | nil,
          failure_balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          failure_code: String.t() | nil,
          failure_message: String.t() | nil,
          id: String.t(),
          livemode: boolean,
          metadata: map | nil,
          method: String.t(),
          object: String.t(),
          original_payout: Dhc.Stripe.Payout.t() | String.t() | nil,
          payout_method: String.t() | nil,
          reconciliation_status: String.t(),
          reversed_by: Dhc.Stripe.Payout.t() | String.t() | nil,
          source_type: String.t(),
          statement_descriptor: String.t() | nil,
          status: String.t(),
          trace_id: Dhc.Stripe.PayoutsTraceId.t() | nil,
          type: String.t()
        }

  defstruct [
    :amount,
    :application_fee,
    :application_fee_amount,
    :arrival_date,
    :automatic,
    :balance_transaction,
    :created,
    :currency,
    :description,
    :destination,
    :failure_balance_transaction,
    :failure_code,
    :failure_message,
    :id,
    :livemode,
    :metadata,
    :method,
    :object,
    :original_payout,
    :payout_method,
    :reconciliation_status,
    :reversed_by,
    :source_type,
    :statement_descriptor,
    :status,
    :trace_id,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      application_fee: {:union, [:string, {Dhc.Stripe.ApplicationFee, :t}]},
      application_fee_amount: :integer,
      arrival_date: {:integer, "unix-time"},
      automatic: :boolean,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      description: :string,
      destination:
        {:union,
         [
           :string,
           {Dhc.Stripe.BankAccount, :t},
           {Dhc.Stripe.Card, :t},
           {Dhc.Stripe.DeletedBankAccount, :t},
           {Dhc.Stripe.DeletedCard, :t}
         ]},
      failure_balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      failure_code: :string,
      failure_message: :string,
      id: :string,
      livemode: :boolean,
      metadata: :map,
      method: :string,
      object: {:const, "payout"},
      original_payout: {:union, [:string, {Dhc.Stripe.Payout, :t}]},
      payout_method: :string,
      reconciliation_status: {:enum, ["completed", "in_progress", "not_applicable"]},
      reversed_by: {:union, [:string, {Dhc.Stripe.Payout, :t}]},
      source_type: :string,
      statement_descriptor: :string,
      status: :string,
      trace_id: {Dhc.Stripe.PayoutsTraceId, :t},
      type: {:enum, ["bank_account", "card"]}
    ]
  end
end
