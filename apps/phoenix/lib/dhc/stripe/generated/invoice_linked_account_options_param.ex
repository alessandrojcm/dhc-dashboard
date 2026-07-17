defmodule Dhc.Stripe.InvoiceLinkedAccountOptionsParam do
  @moduledoc """
  Provides struct and types for a InvoiceLinkedAccountOptionsParam
  """

  @type t :: %__MODULE__{
          filters: Dhc.Stripe.InvoiceLinkedAccountOptionsFiltersParam.t() | nil,
          permissions: [String.t()] | nil,
          prefetch: [String.t()] | nil
        }

  defstruct [:filters, :permissions, :prefetch]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      filters: {Dhc.Stripe.InvoiceLinkedAccountOptionsFiltersParam, :t},
      permissions: [enum: ["balances", "ownership", "payment_method", "transactions"]],
      prefetch: [enum: ["balances", "ownership", "transactions"]]
    ]
  end
end
