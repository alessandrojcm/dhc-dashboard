defmodule Dhc.Stripe.IssuingAuthorizationFleetFuelPriceData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFleetFuelPriceData
  """

  @type t :: %__MODULE__{gross_amount_decimal: String.t() | nil}

  defstruct [:gross_amount_decimal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [gross_amount_decimal: {:string, "decimal"}]
  end
end
