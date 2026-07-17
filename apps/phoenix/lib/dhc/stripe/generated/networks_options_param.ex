defmodule Dhc.Stripe.NetworksOptionsParam do
  @moduledoc """
  Provides struct and types for a NetworksOptionsParam
  """

  @type t :: %__MODULE__{requested: [String.t()] | nil}

  defstruct [:requested]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [requested: [enum: ["ach", "us_domestic_wire"]]]
  end
end
