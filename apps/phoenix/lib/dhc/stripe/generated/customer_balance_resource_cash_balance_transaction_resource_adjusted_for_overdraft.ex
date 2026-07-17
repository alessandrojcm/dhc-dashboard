defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAdjustedForOverdraft do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceAdjustedForOverdraft
  """

  @type t :: %__MODULE__{
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t(),
          linked_transaction: Dhc.Stripe.CustomerCashBalanceTransaction.t() | String.t()
        }

  defstruct [:balance_transaction, :linked_transaction]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      linked_transaction: {:union, [:string, {Dhc.Stripe.CustomerCashBalanceTransaction, :t}]}
    ]
  end
end
