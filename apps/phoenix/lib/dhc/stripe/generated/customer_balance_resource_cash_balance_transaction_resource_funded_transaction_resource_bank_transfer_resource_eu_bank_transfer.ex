defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceEuBankTransfer do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceEuBankTransfer
  """

  @type t :: %__MODULE__{
          bic: String.t() | nil,
          iban_last4: String.t() | nil,
          sender_name: String.t() | nil
        }

  defstruct [:bic, :iban_last4, :sender_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bic: :string, iban_last4: :string, sender_name: :string]
  end
end
