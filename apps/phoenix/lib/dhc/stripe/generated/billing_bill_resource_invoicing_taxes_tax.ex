defmodule Dhc.Stripe.BillingBillResourceInvoicingTaxesTax do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingTaxesTax
  """

  @type t :: %__MODULE__{
          amount: integer,
          tax_behavior: String.t(),
          tax_rate_details: Dhc.Stripe.BillingBillResourceInvoicingTaxesTaxRateDetails.t() | nil,
          taxability_reason: String.t(),
          taxable_amount: integer | nil,
          type: String.t()
        }

  defstruct [
    :amount,
    :tax_behavior,
    :tax_rate_details,
    :taxability_reason,
    :taxable_amount,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      tax_behavior: {:enum, ["exclusive", "inclusive"]},
      tax_rate_details: {Dhc.Stripe.BillingBillResourceInvoicingTaxesTaxRateDetails, :t},
      taxability_reason:
        {:enum,
         [
           "customer_exempt",
           "not_available",
           "not_collecting",
           "not_subject_to_tax",
           "not_supported",
           "portion_product_exempt",
           "portion_reduced_rated",
           "portion_standard_rated",
           "product_exempt",
           "product_exempt_holiday",
           "proportionally_rated",
           "reduced_rated",
           "reverse_charge",
           "standard_rated",
           "taxable_basis_reduced",
           "zero_rated"
         ]},
      taxable_amount: :integer,
      type: {:const, "tax_rate_details"}
    ]
  end
end
