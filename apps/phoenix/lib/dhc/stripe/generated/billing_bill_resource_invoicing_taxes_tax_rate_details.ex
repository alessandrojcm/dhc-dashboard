defmodule Dhc.Stripe.BillingBillResourceInvoicingTaxesTaxRateDetails do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingTaxesTaxRateDetails
  """

  @type t :: %__MODULE__{tax_rate: Dhc.Stripe.TaxRate.t() | String.t()}

  defstruct [:tax_rate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax_rate: {:union, [:string, {Dhc.Stripe.TaxRate, :t}]}]
  end
end
