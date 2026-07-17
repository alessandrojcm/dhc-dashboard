defmodule Dhc.Stripe.IssuingCardholderAddress do
  @moduledoc """
  Provides struct and type for a IssuingCardholderAddress
  """

  @type t :: %__MODULE__{address: Dhc.Stripe.Address.t()}

  defstruct [:address]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [address: {Dhc.Stripe.Address, :t}]
  end
end
