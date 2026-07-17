defmodule Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceQuoteParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingParentsInvoiceQuoteParent
  """

  @type t :: %__MODULE__{quote: String.t()}

  defstruct [:quote]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [quote: :string]
  end
end
