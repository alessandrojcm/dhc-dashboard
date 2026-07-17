defmodule Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptionsFilters do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsUsBankAccountLinkedAccountOptionsFilters
  """

  @type t :: %__MODULE__{account_subcategories: [String.t()] | nil}

  defstruct [:account_subcategories]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [account_subcategories: [enum: ["checking", "savings"]]]
  end
end
