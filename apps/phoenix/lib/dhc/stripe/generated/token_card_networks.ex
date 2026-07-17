defmodule Dhc.Stripe.TokenCardNetworks do
  @moduledoc """
  Provides struct and type for a TokenCardNetworks
  """

  @type t :: %__MODULE__{preferred: String.t() | nil}

  defstruct [:preferred]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [preferred: :string]
  end
end
