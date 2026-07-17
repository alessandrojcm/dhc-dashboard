defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceUsBankTransfer do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceUsBankTransfer
  """

  @type t :: %__MODULE__{network: String.t() | nil, sender_name: String.t() | nil}

  defstruct [:network, :sender_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [network: {:enum, ["ach", "domestic_wire_us", "swift"]}, sender_name: :string]
  end
end
