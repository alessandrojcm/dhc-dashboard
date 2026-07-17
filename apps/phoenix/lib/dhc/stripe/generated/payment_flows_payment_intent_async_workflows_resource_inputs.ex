defmodule Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputs do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputs
  """

  @type t :: %__MODULE__{
          tax:
            Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputsResourceTax.t() | nil
        }

  defstruct [:tax]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax: {Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputsResourceTax, :t}]
  end
end
