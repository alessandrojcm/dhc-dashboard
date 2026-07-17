defmodule Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccount do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsUsBankAccount
  """

  @type t :: %__MODULE__{
          financial_connections:
            Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptions.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:financial_connections, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      financial_connections:
        {Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptions, :t},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
