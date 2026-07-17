defmodule Dhc.Stripe.InlineProductParams do
  @moduledoc """
  Provides struct and type for a InlineProductParams
  """

  @type t :: %__MODULE__{
          active: boolean | nil,
          id: String.t() | nil,
          metadata: map | nil,
          name: String.t(),
          statement_descriptor: String.t() | nil,
          tax_code: String.t() | nil,
          unit_label: String.t() | nil
        }

  defstruct [:active, :id, :metadata, :name, :statement_descriptor, :tax_code, :unit_label]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      id: :string,
      metadata: :map,
      name: :string,
      statement_descriptor: :string,
      tax_code: :string,
      unit_label: :string
    ]
  end
end
