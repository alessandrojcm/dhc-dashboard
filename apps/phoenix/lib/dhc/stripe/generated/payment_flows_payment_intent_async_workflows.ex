defmodule Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflows do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPaymentIntentAsyncWorkflows
  """

  @type t :: %__MODULE__{
          inputs: Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputs.t() | nil
        }

  defstruct [:inputs]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [inputs: {Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputs, :t}]
  end
end
