defmodule Dhc.Stripe.PaymentIntentAmountDetailsLineItem do
  @moduledoc """
  Provides struct and type for a PaymentIntentAmountDetailsLineItem
  """

  @type t :: %__MODULE__{
          discount_amount: integer | nil,
          id: String.t(),
          object: String.t(),
          payment_method_options:
            Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourcePaymentMethodOptions.t()
            | nil,
          product_code: String.t() | nil,
          product_name: String.t(),
          quantity: integer,
          tax:
            Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourceTax.t()
            | nil,
          unit_cost: integer,
          unit_of_measure: String.t() | nil
        }

  defstruct [
    :discount_amount,
    :id,
    :object,
    :payment_method_options,
    :product_code,
    :product_name,
    :quantity,
    :tax,
    :unit_cost,
    :unit_of_measure
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discount_amount: :integer,
      id: :string,
      object: {:const, "payment_intent_amount_details_line_item"},
      payment_method_options:
        {Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourcePaymentMethodOptions,
         :t},
      product_code: :string,
      product_name: :string,
      quantity: :integer,
      tax:
        {Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourceTax, :t},
      unit_cost: :integer,
      unit_of_measure: :string
    ]
  end
end
