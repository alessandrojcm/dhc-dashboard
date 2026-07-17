defmodule Dhc.Stripe.TransferDataParams do
  @moduledoc """
  Provides struct and type for a TransferDataParams
  """

  @type t :: %__MODULE__{amount: integer | nil, destination: String.t()}

  defstruct [:amount, :destination]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, destination: :string]
  end
end
