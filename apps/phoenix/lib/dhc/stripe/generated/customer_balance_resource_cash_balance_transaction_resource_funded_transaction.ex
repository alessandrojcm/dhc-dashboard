defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransaction do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransaction
  """

  @type t :: %__MODULE__{
          bank_transfer:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransfer.t()
        }

  defstruct [:bank_transfer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_transfer:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransfer,
         :t}
    ]
  end
end
