defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentCommonWallet do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsCardPresentCommonWallet
  """

  @type t :: %__MODULE__{type: String.t()}

  defstruct [:type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [type: {:enum, ["apple_pay", "google_pay", "samsung_pay", "unknown"]}]
  end
end
