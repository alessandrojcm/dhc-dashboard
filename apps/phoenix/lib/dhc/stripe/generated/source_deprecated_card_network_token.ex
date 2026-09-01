defmodule Dhc.Stripe.SourceDeprecatedCardNetworkToken do
  @moduledoc """
  Provides struct and type for a SourceDeprecatedCardNetworkToken
  """

  @type t :: %__MODULE__{number: String.t() | nil}

  defstruct [:number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [number: :string]
  end
end
