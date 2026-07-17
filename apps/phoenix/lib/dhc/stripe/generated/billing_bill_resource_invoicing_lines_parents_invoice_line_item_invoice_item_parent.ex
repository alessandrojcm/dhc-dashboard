defmodule Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemInvoiceItemParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingLinesParentsInvoiceLineItemInvoiceItemParent
  """

  @type t :: %__MODULE__{
          invoice_item: String.t(),
          proration: boolean,
          proration_details:
            Dhc.Stripe.BillingBillResourceInvoicingLinesCommonProrationDetails.t() | nil,
          subscription: String.t() | nil
        }

  defstruct [:invoice_item, :proration, :proration_details, :subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      invoice_item: :string,
      proration: :boolean,
      proration_details: {Dhc.Stripe.BillingBillResourceInvoicingLinesCommonProrationDetails, :t},
      subscription: :string
    ]
  end
end
