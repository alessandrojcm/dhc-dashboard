defmodule Dhc.Stripe.CustomerTax do
  @moduledoc """
  Provides struct and type for a CustomerTax
  """

  @type t :: %__MODULE__{
          automatic_tax: String.t(),
          ip_address: String.t() | nil,
          location: Dhc.Stripe.CustomerTaxLocation.t() | nil,
          provider: String.t()
        }

  defstruct [:automatic_tax, :ip_address, :location, :provider]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      automatic_tax: {:enum, ["failed", "not_collecting", "supported", "unrecognized_location"]},
      ip_address: :string,
      location: {Dhc.Stripe.CustomerTaxLocation, :t},
      provider: {:enum, ["anrok", "avalara", "sphere", "stripe"]}
    ]
  end
end
