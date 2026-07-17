defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceJpBankTransfer do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceJpBankTransfer
  """

  @type t :: %__MODULE__{
          sender_bank: String.t() | nil,
          sender_branch: String.t() | nil,
          sender_name: String.t() | nil
        }

  defstruct [:sender_bank, :sender_branch, :sender_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [sender_bank: :string, sender_branch: :string, sender_name: :string]
  end
end
