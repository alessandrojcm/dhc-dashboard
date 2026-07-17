defmodule Dhc.Stripe.TransferDataSpecs do
  @moduledoc """
  Provides struct and types for a TransferDataSpecs
  """

  @type t :: %__MODULE__{amount_percent: number | nil, destination: String.t()}

  defstruct [:amount_percent, :destination]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_percent: :number, destination: :string]
  end
end
