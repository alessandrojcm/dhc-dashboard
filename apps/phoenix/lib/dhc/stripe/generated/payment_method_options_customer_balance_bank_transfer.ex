defmodule Dhc.Stripe.PaymentMethodOptionsCustomerBalanceBankTransfer do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsCustomerBalanceBankTransfer
  """

  @type t :: %__MODULE__{
          eu_bank_transfer: Dhc.Stripe.PaymentMethodOptionsCustomerBalanceEuBankAccount.t() | nil,
          requested_address_types: [String.t()] | nil,
          type: String.t() | nil
        }

  defstruct [:eu_bank_transfer, :requested_address_types, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      eu_bank_transfer: {Dhc.Stripe.PaymentMethodOptionsCustomerBalanceEuBankAccount, :t},
      requested_address_types: [
        enum: ["aba", "iban", "sepa", "sort_code", "spei", "swift", "zengin"]
      ],
      type:
        {:enum,
         [
           "eu_bank_transfer",
           "gb_bank_transfer",
           "jp_bank_transfer",
           "mx_bank_transfer",
           "us_bank_transfer"
         ]}
    ]
  end
end
