defmodule Dhc.Stripe.DeletedBankAccount do
  @moduledoc """
  Provides struct and type for a DeletedBankAccount
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
    [currency: :string, deleted: {:const, true}, id: :string, object: {:const, "bank_account"}]
  end
end
