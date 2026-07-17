defmodule Dhc.Stripe.Rule do
  @moduledoc """
  Provides struct and type for a Rule
  """

  @type t :: %__MODULE__{action: String.t(), id: String.t(), predicate: String.t()}

  defstruct [:action, :id, :predicate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [action: :string, id: :string, predicate: :string]
  end
end
