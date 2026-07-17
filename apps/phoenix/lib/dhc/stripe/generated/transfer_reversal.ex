defmodule Dhc.Stripe.TransferReversal do
  @moduledoc """
  Provides struct and type for a TransferReversal
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          destination_payment_refund: Dhc.Stripe.Refund.t() | String.t() | nil,
          id: String.t(),
          metadata: map | nil,
          object: String.t(),
          source_refund: Dhc.Stripe.Refund.t() | String.t() | nil,
          transfer: Dhc.Stripe.Transfer.t() | String.t()
        }

  defstruct [
    :amount,
    :balance_transaction,
    :created,
    :currency,
    :destination_payment_refund,
    :id,
    :metadata,
    :object,
    :source_refund,
    :transfer
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      destination_payment_refund: {:union, [:string, {Dhc.Stripe.Refund, :t}]},
      id: :string,
      metadata: :map,
      object: {:const, "transfer_reversal"},
      source_refund: {:union, [:string, {Dhc.Stripe.Refund, :t}]},
      transfer: {:union, [:string, {Dhc.Stripe.Transfer, :t}]}
    ]
  end
end
