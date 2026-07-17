defmodule Dhc.Stripe.IssuingTransactionReceiptData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionReceiptData
  """

  @type t :: %__MODULE__{
          description: String.t() | nil,
          quantity: number | nil,
          total: integer | nil,
          unit_cost: integer | nil
        }

  defstruct [:description, :quantity, :total, :unit_cost]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, quantity: :number, total: :integer, unit_cost: :integer]
  end
end
