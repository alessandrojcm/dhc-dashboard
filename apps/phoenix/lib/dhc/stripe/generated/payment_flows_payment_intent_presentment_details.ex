defmodule Dhc.Stripe.PaymentFlowsPaymentIntentPresentmentDetails do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPaymentIntentPresentmentDetails
  """

  @type t :: %__MODULE__{presentment_amount: integer, presentment_currency: String.t()}

  defstruct [:presentment_amount, :presentment_currency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [presentment_amount: :integer, presentment_currency: :string]
  end
end
