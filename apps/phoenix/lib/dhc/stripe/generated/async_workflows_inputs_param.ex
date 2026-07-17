defmodule Dhc.Stripe.AsyncWorkflowsInputsParam do
  @moduledoc """
  Provides struct and types for a AsyncWorkflowsInputsParam
  """

  @type t :: %__MODULE__{tax: Dhc.Stripe.AsyncWorkflowsInputsTaxParam.t() | nil}

  defstruct [:tax]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax: {Dhc.Stripe.AsyncWorkflowsInputsTaxParam, :t}]
  end
end
