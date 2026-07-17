defmodule Dhc.Stripe.BillingBillResourceInvoicingLinesParentsInvoiceLineItemSubscriptionItemParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingLinesParentsInvoiceLineItemSubscriptionItemParent
  """

  @type t :: %__MODULE__{
          invoice_item: String.t() | nil,
          proration: boolean,
          proration_details:
            Dhc.Stripe.BillingBillResourceInvoicingLinesCommonProrationDetails.t() | nil,
          subscription: String.t() | nil,
          subscription_item: String.t()
        }

  defstruct [:invoice_item, :proration, :proration_details, :subscription, :subscription_item]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      invoice_item: :string,
      proration: :boolean,
      proration_details: {Dhc.Stripe.BillingBillResourceInvoicingLinesCommonProrationDetails, :t},
      subscription: :string,
      subscription_item: :string
    ]
  end
end
