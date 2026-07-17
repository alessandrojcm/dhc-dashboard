defmodule Dhc.Stripe.AsyncWorkflowsParam do
  @moduledoc """
  Provides struct and types for a AsyncWorkflowsParam
  """

  @type t :: %__MODULE__{inputs: Dhc.Stripe.AsyncWorkflowsInputsParam.t() | nil}

  defstruct [:inputs]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [inputs: {Dhc.Stripe.AsyncWorkflowsInputsParam, :t}]
  end
end
