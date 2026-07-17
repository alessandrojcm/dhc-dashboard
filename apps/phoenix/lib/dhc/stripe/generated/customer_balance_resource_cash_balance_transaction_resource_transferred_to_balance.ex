defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceTransferredToBalance do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceTransferredToBalance
  """

  @type t :: %__MODULE__{balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t()}

  defstruct [:balance_transaction]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]}]
  end
end
