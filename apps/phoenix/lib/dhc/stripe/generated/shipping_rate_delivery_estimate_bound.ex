defmodule Dhc.Stripe.ShippingRateDeliveryEstimateBound do
  @moduledoc """
  Provides struct and type for a ShippingRateDeliveryEstimateBound
  """

  @type t :: %__MODULE__{unit: String.t(), value: integer}

  defstruct [:unit, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [unit: {:enum, ["business_day", "day", "hour", "month", "week"]}, value: :integer]
  end
end
