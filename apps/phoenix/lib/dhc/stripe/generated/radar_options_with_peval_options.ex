defmodule Dhc.Stripe.RadarOptionsWithPevalOptions do
  @moduledoc """
  Provides struct and types for a RadarOptionsWithPevalOptions
  """

  @type t :: %__MODULE__{referrer: String.t() | nil, session: String.t() | nil}

  defstruct [:referrer, :session]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [referrer: {:union, [:string, const: ""]}, session: :string]
  end
end
