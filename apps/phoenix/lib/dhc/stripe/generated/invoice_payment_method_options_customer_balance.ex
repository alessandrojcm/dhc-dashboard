defmodule Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalance do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsCustomerBalance
  """

  @type t :: %__MODULE__{
          bank_transfer:
            Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransfer.t() | nil,
          funding_type: String.t() | nil
        }

  defstruct [:bank_transfer, :funding_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_transfer: {Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalanceBankTransfer, :t},
      funding_type: {:const, "bank_transfer"}
    ]
  end
end
