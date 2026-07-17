defmodule Dhc.Stripe.Period do
  @moduledoc """
  Provides struct and type for a Period
  """

  @type t :: %__MODULE__{end: integer, start: integer}

  defstruct [:end, :start]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end: {:integer, "unix-time"}, start: {:integer, "unix-time"}]
  end
end
