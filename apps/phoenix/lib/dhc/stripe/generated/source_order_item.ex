defmodule Dhc.Stripe.SourceOrderItem do
  @moduledoc """
  Provides struct and type for a SourceOrderItem
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          currency: String.t() | nil,
          description: String.t() | nil,
          parent: String.t() | nil,
          quantity: integer | nil,
          type: String.t() | nil
        }

  defstruct [:amount, :currency, :description, :parent, :quantity, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: :string,
      description: :string,
      parent: :string,
      quantity: :integer,
      type: :string
    ]
  end
end
