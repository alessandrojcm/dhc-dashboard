defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceGbBankTransfer do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceGbBankTransfer
  """

  @type t :: %__MODULE__{
          account_number_last4: String.t() | nil,
          sender_name: String.t() | nil,
          sort_code: String.t() | nil
        }

  defstruct [:account_number_last4, :sender_name, :sort_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [account_number_last4: :string, sender_name: :string, sort_code: :string]
  end
end
