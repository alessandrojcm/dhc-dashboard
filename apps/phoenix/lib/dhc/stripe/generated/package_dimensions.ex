defmodule Dhc.Stripe.PackageDimensions do
  @moduledoc """
  Provides struct and type for a PackageDimensions
  """

  @type t :: %__MODULE__{height: number, length: number, weight: number, width: number}

  defstruct [:height, :length, :weight, :width]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [height: :number, length: :number, weight: :number, width: :number]
  end
end
