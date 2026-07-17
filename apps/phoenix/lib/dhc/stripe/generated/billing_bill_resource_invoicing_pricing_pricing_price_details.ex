defmodule Dhc.Stripe.BillingBillResourceInvoicingPricingPricingPriceDetails do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingPricingPricingPriceDetails
  """

  @type t :: %__MODULE__{price: Dhc.Stripe.Price.t() | String.t(), product: String.t()}

  defstruct [:price, :product]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [price: {:union, [:string, {Dhc.Stripe.Price, :t}]}, product: :string]
  end
end
