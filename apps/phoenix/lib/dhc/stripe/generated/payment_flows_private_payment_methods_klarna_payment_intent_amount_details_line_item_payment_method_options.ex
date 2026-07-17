defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKlarnaPaymentIntentAmountDetailsLineItemPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsKlarnaPaymentIntentAmountDetailsLineItemPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          image_url: String.t() | nil,
          product_url: String.t() | nil,
          reference: String.t() | nil,
          subscription_reference: String.t() | nil
        }

  defstruct [:image_url, :product_url, :reference, :subscription_reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      image_url: :string,
      product_url: :string,
      reference: :string,
      subscription_reference: :string
    ]
  end
end
