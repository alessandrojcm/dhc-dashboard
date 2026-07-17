defmodule Dhc.Stripe.SourceTypeEps do
  @moduledoc """
  Provides struct and type for a SourceTypeEps
  """

  @type t :: %__MODULE__{reference: String.t() | nil, statement_descriptor: String.t() | nil}

  defstruct [:reference, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference: :string, statement_descriptor: :string]
  end
end
