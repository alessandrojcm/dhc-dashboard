defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceMulticapture do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceMulticapture
  """

  @type t :: %__MODULE__{status: String.t()}

  defstruct [:status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [status: {:enum, ["available", "unavailable"]}]
  end
end
