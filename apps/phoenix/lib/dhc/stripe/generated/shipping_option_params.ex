defmodule Dhc.Stripe.ShippingOptionParams do
  @moduledoc """
  Provides struct and type for a ShippingOptionParams
  """

  @type t :: %__MODULE__{
          shipping_rate: String.t() | nil,
          shipping_rate_data: Dhc.Stripe.MethodParams.t() | nil
        }

  defstruct [:shipping_rate, :shipping_rate_data]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [shipping_rate: :string, shipping_rate_data: {Dhc.Stripe.MethodParams, :t}]
  end
end
