defmodule Dhc.Stripe.FeeRefund do
  @moduledoc """
  Provides struct and type for a FeeRefund
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          fee: Dhc.Stripe.ApplicationFee.t() | String.t(),
          id: String.t(),
          metadata: map | nil,
          object: String.t()
        }

  defstruct [:amount, :balance_transaction, :created, :currency, :fee, :id, :metadata, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      fee: {:union, [:string, {Dhc.Stripe.ApplicationFee, :t}]},
      id: :string,
      metadata: :map,
      object: {:const, "fee_refund"}
    ]
  end
end
