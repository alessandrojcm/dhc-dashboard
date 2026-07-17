defmodule Dhc.Stripe.TaxCode do
  @moduledoc """
  Provides struct and type for a TaxCode
  """

  @type t :: %__MODULE__{
          description: String.t(),
          id: String.t(),
          name: String.t(),
          object: String.t()
        }

  defstruct [:description, :id, :name, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, id: :string, name: :string, object: {:const, "tax_code"}]
  end
end
