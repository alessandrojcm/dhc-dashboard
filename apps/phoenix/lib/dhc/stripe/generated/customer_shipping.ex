defmodule Dhc.Stripe.CustomerShipping do
  @moduledoc """
  Provides struct and types for a CustomerShipping
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.OptionalFieldsCustomerAddress.t(),
          name: String.t(),
          phone: String.t() | nil
        }

  defstruct [:address, :name, :phone]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [address: {Dhc.Stripe.OptionalFieldsCustomerAddress, :t}, name: :string, phone: :string]
  end
end
