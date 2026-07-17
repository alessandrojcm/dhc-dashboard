defmodule Dhc.Stripe.IssuingTransactionFleetReportedBreakdown do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFleetReportedBreakdown
  """

  @type t :: %__MODULE__{
          fuel: Dhc.Stripe.IssuingTransactionFleetFuelPriceData.t() | nil,
          non_fuel: Dhc.Stripe.IssuingTransactionFleetNonFuelPriceData.t() | nil,
          tax: Dhc.Stripe.IssuingTransactionFleetTaxData.t() | nil
        }

  defstruct [:fuel, :non_fuel, :tax]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      fuel: {Dhc.Stripe.IssuingTransactionFleetFuelPriceData, :t},
      non_fuel: {Dhc.Stripe.IssuingTransactionFleetNonFuelPriceData, :t},
      tax: {Dhc.Stripe.IssuingTransactionFleetTaxData, :t}
    ]
  end
end
