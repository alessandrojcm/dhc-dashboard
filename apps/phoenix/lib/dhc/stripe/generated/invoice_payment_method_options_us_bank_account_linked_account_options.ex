defmodule Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptions do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptions
  """

  @type t :: %__MODULE__{
          filters:
            Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptionsFilters.t()
            | nil,
          permissions: [String.t()] | nil,
          prefetch: [String.t()] | nil
        }

  defstruct [:filters, :permissions, :prefetch]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      filters:
        {Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptionsFilters, :t},
      permissions: [enum: ["balances", "ownership", "payment_method", "transactions"]],
      prefetch: [enum: ["balances", "ownership", "transactions"]]
    ]
  end
end
