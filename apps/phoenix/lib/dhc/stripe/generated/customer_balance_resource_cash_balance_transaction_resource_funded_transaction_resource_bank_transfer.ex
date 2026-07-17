defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransfer do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransfer
  """

  @type t :: %__MODULE__{
          eu_bank_transfer:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceEuBankTransfer.t()
            | nil,
          gb_bank_transfer:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceGbBankTransfer.t()
            | nil,
          jp_bank_transfer:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceJpBankTransfer.t()
            | nil,
          reference: String.t() | nil,
          type: String.t(),
          us_bank_transfer:
            Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceUsBankTransfer.t()
            | nil
        }

  defstruct [
    :eu_bank_transfer,
    :gb_bank_transfer,
    :jp_bank_transfer,
    :reference,
    :type,
    :us_bank_transfer
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      eu_bank_transfer:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceEuBankTransfer,
         :t},
      gb_bank_transfer:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceGbBankTransfer,
         :t},
      jp_bank_transfer:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceJpBankTransfer,
         :t},
      reference: :string,
      type:
        {:enum,
         [
           "eu_bank_transfer",
           "gb_bank_transfer",
           "jp_bank_transfer",
           "mx_bank_transfer",
           "us_bank_transfer"
         ]},
      us_bank_transfer:
        {Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceFundedTransactionResourceBankTransferResourceUsBankTransfer,
         :t}
    ]
  end
end
