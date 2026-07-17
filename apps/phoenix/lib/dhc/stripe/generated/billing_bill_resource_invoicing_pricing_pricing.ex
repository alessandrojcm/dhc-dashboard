defmodule Dhc.Stripe.BillingBillResourceInvoicingPricingPricing do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingPricingPricing
  """

  @type t :: %__MODULE__{
          price_details:
            Dhc.Stripe.BillingBillResourceInvoicingPricingPricingPriceDetails.t() | nil,
          type: String.t(),
          unit_amount_decimal: String.t() | nil
        }

  defstruct [:price_details, :type, :unit_amount_decimal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      price_details: {Dhc.Stripe.BillingBillResourceInvoicingPricingPricingPriceDetails, :t},
      type: {:const, "price_details"},
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
