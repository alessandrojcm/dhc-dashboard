defmodule Dhc.Stripe.DeletedProduct do
  @moduledoc """
  Provides struct and type for a DeletedProduct
  """

  @type t :: %__MODULE__{deleted: true, id: String.t(), object: String.t()}

  defstruct [:deleted, :id, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [deleted: {:const, true}, id: :string, object: {:const, "product"}]
  end
end
