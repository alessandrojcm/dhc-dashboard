defmodule Dhc.Stripe.ShippingRateDeliveryEstimate do
  @moduledoc """
  Provides struct and type for a ShippingRateDeliveryEstimate
  """

  @type t :: %__MODULE__{
          maximum: Dhc.Stripe.ShippingRateDeliveryEstimateBound.t() | nil,
          minimum: Dhc.Stripe.ShippingRateDeliveryEstimateBound.t() | nil
        }

  defstruct [:maximum, :minimum]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      maximum: {Dhc.Stripe.ShippingRateDeliveryEstimateBound, :t},
      minimum: {Dhc.Stripe.ShippingRateDeliveryEstimateBound, :t}
    ]
  end
end
