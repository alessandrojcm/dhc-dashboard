defmodule Dhc.Stripe.Shipping do
  @moduledoc """
  Provides struct and types for a Shipping
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          carrier: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil,
          tracking_number: String.t() | nil
        }

  defstruct [:address, :carrier, :name, :phone, :tracking_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      carrier: :string,
      name: :string,
      phone: :string,
      tracking_number: :string
    ]
  end
end
