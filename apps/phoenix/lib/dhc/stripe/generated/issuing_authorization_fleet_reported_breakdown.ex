defmodule Dhc.Stripe.IssuingAuthorizationFleetReportedBreakdown do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFleetReportedBreakdown
  """

  @type t :: %__MODULE__{
          fuel: Dhc.Stripe.IssuingAuthorizationFleetFuelPriceData.t() | nil,
          non_fuel: Dhc.Stripe.IssuingAuthorizationFleetNonFuelPriceData.t() | nil,
          tax: Dhc.Stripe.IssuingAuthorizationFleetTaxData.t() | nil
        }

  defstruct [:fuel, :non_fuel, :tax]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      fuel: {Dhc.Stripe.IssuingAuthorizationFleetFuelPriceData, :t},
      non_fuel: {Dhc.Stripe.IssuingAuthorizationFleetNonFuelPriceData, :t},
      tax: {Dhc.Stripe.IssuingAuthorizationFleetTaxData, :t}
    ]
  end
end
