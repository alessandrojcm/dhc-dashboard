defmodule Dhc.Stripe.DateOfBirth do
  @moduledoc """
  Provides struct and types for a DateOfBirth
  """

  @type t :: %__MODULE__{day: integer, month: integer, year: integer}

  defstruct [:day, :month, :year]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [day: :integer, month: :integer, year: :integer]
  end
end
