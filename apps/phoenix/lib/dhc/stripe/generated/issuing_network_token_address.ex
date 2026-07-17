defmodule Dhc.Stripe.IssuingNetworkTokenAddress do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenAddress
  """

  @type t :: %__MODULE__{line1: String.t(), postal_code: String.t()}

  defstruct [:line1, :postal_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [line1: :string, postal_code: :string]
  end
end
