defmodule Dhc.Stripe.IssuingAuthorizationFuelData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFuelData
  """

  @type t :: %__MODULE__{
          industry_product_code: String.t() | nil,
          quantity_decimal: String.t() | nil,
          type: String.t() | nil,
          unit: String.t() | nil,
          unit_cost_decimal: String.t() | nil
        }

  defstruct [:industry_product_code, :quantity_decimal, :type, :unit, :unit_cost_decimal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      industry_product_code: :string,
      quantity_decimal: {:string, "decimal"},
      type: {:enum, ["diesel", "other", "unleaded_plus", "unleaded_regular", "unleaded_super"]},
      unit:
        {:enum,
         [
           "charging_minute",
           "imperial_gallon",
           "kilogram",
           "kilowatt_hour",
           "liter",
           "other",
           "pound",
           "us_gallon"
         ]},
      unit_cost_decimal: {:string, "decimal"}
    ]
  end
end
