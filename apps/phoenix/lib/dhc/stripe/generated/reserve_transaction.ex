defmodule Dhc.Stripe.ReserveTransaction do
  @moduledoc """
  Provides struct and type for a ReserveTransaction
  """

  @type t :: %__MODULE__{
          amount: integer,
          currency: String.t(),
          description: String.t() | nil,
          id: String.t(),
          object: String.t()
        }

  defstruct [:amount, :currency, :description, :id, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: {:string, "currency"},
      description: :string,
      id: :string,
      object: {:const, "reserve_transaction"}
    ]
  end
end
