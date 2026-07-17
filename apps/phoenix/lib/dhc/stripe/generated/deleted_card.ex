defmodule Dhc.Stripe.DeletedCard do
  @moduledoc """
  Provides struct and type for a DeletedCard
  """

  @type t :: %__MODULE__{
          currency: String.t() | nil,
          deleted: true,
          id: String.t(),
          object: String.t()
        }

  defstruct [:currency, :deleted, :id, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [currency: :string, deleted: {:const, true}, id: :string, object: {:const, "card"}]
  end
end
