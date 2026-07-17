defmodule Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransferEuBankTransfer do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsCustomerBalanceBankTransferEuBankTransfer
  """

  @type t :: %__MODULE__{country: String.t()}

  defstruct [:country]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [country: {:enum, ["BE", "DE", "ES", "FR", "IE", "NL"]}]
  end
end
