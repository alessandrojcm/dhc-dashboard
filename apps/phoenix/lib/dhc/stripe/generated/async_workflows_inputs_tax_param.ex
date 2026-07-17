defmodule Dhc.Stripe.AsyncWorkflowsInputsTaxParam do
  @moduledoc """
  Provides struct and types for a AsyncWorkflowsInputsTaxParam
  """

  @type t :: %__MODULE__{calculation: String.t()}

  defstruct [:calculation]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [calculation: {:union, [:string, const: ""]}]
  end
end
