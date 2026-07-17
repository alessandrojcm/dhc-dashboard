defmodule Dhc.Stripe.DisputePaymentMethodDetails do
  @moduledoc """
  Provides struct and type for a DisputePaymentMethodDetails
  """

  @type t :: %__MODULE__{
          amazon_pay: Dhc.Stripe.DisputePaymentMethodDetailsAmazonPay.t() | nil,
          card: Dhc.Stripe.DisputePaymentMethodDetailsCard.t() | nil,
          klarna: Dhc.Stripe.DisputePaymentMethodDetailsKlarna.t() | nil,
          paypal: Dhc.Stripe.DisputePaymentMethodDetailsPaypal.t() | nil,
          type: String.t()
        }

  defstruct [:amazon_pay, :card, :klarna, :paypal, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amazon_pay: {Dhc.Stripe.DisputePaymentMethodDetailsAmazonPay, :t},
      card: {Dhc.Stripe.DisputePaymentMethodDetailsCard, :t},
      klarna: {Dhc.Stripe.DisputePaymentMethodDetailsKlarna, :t},
      paypal: {Dhc.Stripe.DisputePaymentMethodDetailsPaypal, :t},
      type: {:enum, ["amazon_pay", "card", "klarna", "paypal"]}
    ]
  end
end
