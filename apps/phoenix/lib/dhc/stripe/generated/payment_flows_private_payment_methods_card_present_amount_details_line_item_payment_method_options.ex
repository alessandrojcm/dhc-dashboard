defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentAmountDetailsLineItemPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsCardPresentAmountDetailsLineItemPaymentMethodOptions
  """

  @type t :: %__MODULE__{commodity_code: String.t() | nil}

  defstruct [:commodity_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [commodity_code: :string]
  end
end
