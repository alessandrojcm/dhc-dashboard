defmodule Dhc.Stripe.TransformQuantity do
  @moduledoc """
  Provides struct and type for a TransformQuantity
  """

  @type t :: %__MODULE__{divide_by: integer, round: String.t()}

  defstruct [:divide_by, :round]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [divide_by: :integer, round: {:enum, ["down", "up"]}]
  end
end
