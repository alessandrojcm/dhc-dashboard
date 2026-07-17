defmodule Dhc.Stripe.KlarnaPayerDetails do
  @moduledoc """
  Provides struct and type for a KlarnaPayerDetails
  """

  @type t :: %__MODULE__{address: Dhc.Stripe.KlarnaAddress.t() | nil}

  defstruct [:address]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [address: {Dhc.Stripe.KlarnaAddress, :t}]
  end
end
