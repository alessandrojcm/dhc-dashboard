defmodule Dhc.Stripe.OptionalFieldsShipping do
  @moduledoc """
  Provides struct and types for a OptionalFieldsShipping
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.OptionalFieldsAddress.t(),
          carrier: String.t() | nil,
          name: String.t(),
          phone: String.t() | nil,
          tracking_number: String.t() | nil
        }

  defstruct [:address, :carrier, :name, :phone, :tracking_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.OptionalFieldsAddress, :t},
      carrier: :string,
      name: :string,
      phone: :string,
      tracking_number: :string
    ]
  end
end
