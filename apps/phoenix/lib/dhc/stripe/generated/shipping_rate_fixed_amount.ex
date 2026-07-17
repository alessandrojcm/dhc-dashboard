defmodule Dhc.Stripe.ShippingRateFixedAmount do
  @moduledoc """
  Provides struct and type for a ShippingRateFixedAmount
  """

  @type t :: %__MODULE__{amount: integer, currency: String.t(), currency_options: map | nil}

  defstruct [:amount, :currency, :currency_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, currency: {:string, "currency"}, currency_options: :map]
  end
end
