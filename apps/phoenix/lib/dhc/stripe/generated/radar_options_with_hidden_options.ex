defmodule Dhc.Stripe.RadarOptionsWithHiddenOptions do
  @moduledoc """
  Provides struct and types for a RadarOptionsWithHiddenOptions
  """

  @type t :: %__MODULE__{session: String.t() | nil}

  defstruct [:session]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [session: :string]
  end
end
