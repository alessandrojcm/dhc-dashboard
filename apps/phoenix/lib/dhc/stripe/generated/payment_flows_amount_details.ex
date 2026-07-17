defmodule Dhc.Stripe.PaymentFlowsAmountDetails do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetails
  """

  @type t :: %__MODULE__{
          discount_amount: integer | nil,
          error: Dhc.Stripe.PaymentFlowsAmountDetailsResourceError.t() | nil,
          line_items: Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsList.t() | nil,
          shipping: Dhc.Stripe.PaymentFlowsAmountDetailsResourceShipping.t() | nil,
          tax: Dhc.Stripe.PaymentFlowsAmountDetailsResourceTax.t() | nil,
          tip: Dhc.Stripe.PaymentFlowsAmountDetailsClientResourceTip.t() | nil
        }

  defstruct [:discount_amount, :error, :line_items, :shipping, :tax, :tip]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discount_amount: :integer,
      error: {Dhc.Stripe.PaymentFlowsAmountDetailsResourceError, :t},
      line_items: {Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsList, :t},
      shipping: {Dhc.Stripe.PaymentFlowsAmountDetailsResourceShipping, :t},
      tax: {Dhc.Stripe.PaymentFlowsAmountDetailsResourceTax, :t},
      tip: {Dhc.Stripe.PaymentFlowsAmountDetailsClientResourceTip, :t}
    ]
  end
end
