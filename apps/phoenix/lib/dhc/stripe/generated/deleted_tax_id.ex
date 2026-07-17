defmodule Dhc.Stripe.DeletedTaxId do
  @moduledoc """
  Provides struct and type for a DeletedTaxId
  """

  @type t :: %__MODULE__{deleted: true, id: String.t(), object: String.t()}

  defstruct [:deleted, :id, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [deleted: {:const, true}, id: :string, object: {:const, "tax_id"}]
  end
end
