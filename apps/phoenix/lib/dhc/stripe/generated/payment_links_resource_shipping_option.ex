defmodule Dhc.Stripe.PaymentLinksResourceShippingOption do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceShippingOption
  """

  @type t :: %__MODULE__{
          shipping_amount: integer,
          shipping_rate: Dhc.Stripe.ShippingRate.t() | String.t()
        }

  defstruct [:shipping_amount, :shipping_rate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [shipping_amount: :integer, shipping_rate: {:union, [:string, {Dhc.Stripe.ShippingRate, :t}]}]
  end
end
