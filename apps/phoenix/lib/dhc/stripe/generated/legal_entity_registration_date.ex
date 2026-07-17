defmodule Dhc.Stripe.LegalEntityRegistrationDate do
  @moduledoc """
  Provides struct and type for a LegalEntityRegistrationDate
  """

  @type t :: %__MODULE__{day: integer | nil, month: integer | nil, year: integer | nil}

  defstruct [:day, :month, :year]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [day: :integer, month: :integer, year: :integer]
  end
end
