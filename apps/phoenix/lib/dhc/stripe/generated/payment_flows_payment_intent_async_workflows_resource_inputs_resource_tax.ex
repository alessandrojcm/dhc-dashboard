defmodule Dhc.Stripe.PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputsResourceTax do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPaymentIntentAsyncWorkflowsResourceInputsResourceTax
  """

  @type t :: %__MODULE__{calculation: String.t()}

  defstruct [:calculation]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [calculation: :string]
  end
end
