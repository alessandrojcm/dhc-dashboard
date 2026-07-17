defmodule Dhc.Stripe.LineItemsTaxAmount do
  @moduledoc """
  Provides struct and type for a LineItemsTaxAmount
  """

  @type t :: %__MODULE__{
          amount: integer,
          rate: Dhc.Stripe.TaxRate.t(),
          taxability_reason: String.t() | nil,
          taxable_amount: integer | nil
        }

  defstruct [:amount, :rate, :taxability_reason, :taxable_amount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      rate: {Dhc.Stripe.TaxRate, :t},
      taxability_reason:
        {:enum,
         [
           "customer_exempt",
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
      taxable_amount: :integer
    ]
  end
end
