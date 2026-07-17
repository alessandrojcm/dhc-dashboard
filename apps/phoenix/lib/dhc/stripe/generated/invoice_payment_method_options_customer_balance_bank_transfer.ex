defmodule Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransfer do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsCustomerBalanceBankTransfer
  """

  @type t :: %__MODULE__{
          eu_bank_transfer:
            Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransferEuBankTransfer.t()
            | nil,
          type: String.t() | nil
        }

  defstruct [:eu_bank_transfer, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      eu_bank_transfer:
        {Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransferEuBankTransfer, :t},
      type: :string
    ]
  end
end
