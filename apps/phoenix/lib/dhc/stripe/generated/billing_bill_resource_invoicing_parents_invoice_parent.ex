defmodule Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingParentsInvoiceParent
  """

  @type t :: %__MODULE__{
          quote_details:
            Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceQuoteParent.t() | nil,
          subscription_details:
            Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceSubscriptionParent.t() | nil,
          type: String.t()
        }

  defstruct [:quote_details, :subscription_details, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      quote_details: {Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceQuoteParent, :t},
      subscription_details:
        {Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceSubscriptionParent, :t},
      type: {:enum, ["quote_details", "subscription_details"]}
    ]
  end
end
