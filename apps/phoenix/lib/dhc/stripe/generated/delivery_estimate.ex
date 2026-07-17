defmodule Dhc.Stripe.DeliveryEstimate do
  @moduledoc """
  Provides struct and type for a DeliveryEstimate
  """

  @type t :: %__MODULE__{
          maximum: Dhc.Stripe.DeliveryEstimateBound.t() | nil,
          minimum: Dhc.Stripe.DeliveryEstimateBound.t() | nil
        }

  defstruct [:maximum, :minimum]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      maximum: {Dhc.Stripe.DeliveryEstimateBound, :t},
      minimum: {Dhc.Stripe.DeliveryEstimateBound, :t}
    ]
  end
end
