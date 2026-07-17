defmodule Dhc.Stripe.CustomerTaxLocation do
  @moduledoc """
  Provides struct and type for a CustomerTaxLocation
  """

  @type t :: %__MODULE__{country: String.t(), source: String.t(), state: String.t() | nil}

  defstruct [:country, :source, :state]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      country: :string,
      source:
        {:enum, ["billing_address", "ip_address", "payment_method", "shipping_destination"]},
      state: :string
    ]
  end
end
