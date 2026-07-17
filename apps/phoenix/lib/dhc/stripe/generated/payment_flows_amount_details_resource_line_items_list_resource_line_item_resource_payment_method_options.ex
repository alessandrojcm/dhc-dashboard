defmodule Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourcePaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourcePaymentMethodOptions
  """

  @type t :: %__MODULE__{
          card:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPaymentIntentAmountDetailsLineItemPaymentMethodOptions.t()
            | nil,
          card_present:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentAmountDetailsLineItemPaymentMethodOptions.t()
            | nil,
          klarna:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKlarnaPaymentIntentAmountDetailsLineItemPaymentMethodOptions.t()
            | nil,
          paypal:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsPaypalAmountDetailsLineItemPaymentMethodOptions.t()
            | nil
        }

  defstruct [:card, :card_present, :klarna, :paypal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPaymentIntentAmountDetailsLineItemPaymentMethodOptions,
         :t},
      card_present:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentAmountDetailsLineItemPaymentMethodOptions,
         :t},
      klarna:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKlarnaPaymentIntentAmountDetailsLineItemPaymentMethodOptions,
         :t},
      paypal:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsPaypalAmountDetailsLineItemPaymentMethodOptions,
         :t}
    ]
  end
end
