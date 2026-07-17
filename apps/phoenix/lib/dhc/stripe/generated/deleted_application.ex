defmodule Dhc.Stripe.DeletedApplication do
  @moduledoc """
  Provides struct and type for a DeletedApplication
  """

  @type t :: %__MODULE__{
          deleted: true,
          id: String.t(),
          name: String.t() | nil,
          object: String.t()
        }

  defstruct [:deleted, :id, :name, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [deleted: {:const, true}, id: :string, name: :string, object: {:const, "application"}]
  end
end
