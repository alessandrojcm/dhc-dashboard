defmodule Dhc.Stripe.BillingBillResourceInvoicingLinesCommonCreditedItems do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingLinesCommonCreditedItems
  """

  @type t :: %__MODULE__{invoice: String.t(), invoice_line_items: [String.t()]}

  defstruct [:invoice, :invoice_line_items]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [invoice: :string, invoice_line_items: [:string]]
  end
end
