defmodule Dhc.Stripe.Transfer do
  @moduledoc """
  Provides struct and type for a Transfer
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_reversed: integer,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          description: String.t() | nil,
          destination: Dhc.Stripe.Account.t() | String.t() | nil,
          destination_payment: Dhc.Stripe.Charge.t() | String.t() | nil,
          id: String.t(),
          livemode: boolean,
          metadata: map,
          object: String.t(),
          reversals: Dhc.Stripe.TransferReversalList.t(),
          reversed: boolean,
          source_transaction: Dhc.Stripe.Charge.t() | String.t() | nil,
          source_type: String.t() | nil,
          transfer_group: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_reversed,
    :balance_transaction,
    :created,
    :currency,
    :description,
    :destination,
    :destination_payment,
    :id,
    :livemode,
    :metadata,
    :object,
    :reversals,
    :reversed,
    :source_transaction,
    :source_type,
    :transfer_group
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_reversed: :integer,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      description: :string,
      destination: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      destination_payment: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      id: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "transfer"},
      reversals: {Dhc.Stripe.TransferReversalList, :t},
      reversed: :boolean,
      source_transaction: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      source_type: :string,
      transfer_group: :string
    ]
  end
end
