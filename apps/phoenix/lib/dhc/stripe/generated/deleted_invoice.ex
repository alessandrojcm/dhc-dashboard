defmodule Dhc.Stripe.DeletedInvoice do
  @moduledoc """
  Provides struct and type for a DeletedInvoice
  """

  @type t :: %__MODULE__{deleted: true, id: String.t(), object: String.t()}

  defstruct [:deleted, :id, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [deleted: {:const, true}, id: :string, object: {:const, "invoice"}]
  end
end
