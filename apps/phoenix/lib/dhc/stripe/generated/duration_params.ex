defmodule Dhc.Stripe.DurationParams do
  @moduledoc """
  Provides struct and type for a DurationParams
  """

  @type t :: %__MODULE__{interval: String.t(), interval_count: integer | nil}

  defstruct [:interval, :interval_count]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [interval: {:enum, ["day", "month", "week", "year"]}, interval_count: :integer]
  end
end
