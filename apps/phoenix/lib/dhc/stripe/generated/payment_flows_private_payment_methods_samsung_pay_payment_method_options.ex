defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsSamsungPayPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsSamsungPayPaymentMethodOptions
  """

  @type t :: %__MODULE__{capture_method: String.t() | nil}

  defstruct [:capture_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [capture_method: {:const, "manual"}]
  end
end
