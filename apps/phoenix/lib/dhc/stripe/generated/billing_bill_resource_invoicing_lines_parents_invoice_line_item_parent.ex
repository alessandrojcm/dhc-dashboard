defmodule Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingLinesParentsInvoiceLineItemParent
  """

  @type t :: %__MODULE__{
          invoice_item_details:
            Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemInvoiceItemParent.t()
            | nil,
          subscription_item_details:
            Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemSubscriptionItemParent.t()
            | nil,
          type: String.t()
        }

  defstruct [:invoice_item_details, :subscription_item_details, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      invoice_item_details:
        {Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemInvoiceItemParent, :t},
      subscription_item_details:
        {Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemSubscriptionItemParent,
         :t},
      type: {:enum, ["invoice_item_details", "subscription_item_details"]}
    ]
  end
end
