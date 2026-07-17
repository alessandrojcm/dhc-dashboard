defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCustomText do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCustomText
  """

  @type t :: %__MODULE__{
          after_submit: Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition.t() | nil,
          shipping_address: Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition.t() | nil,
          submit: Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition.t() | nil,
          terms_of_service_acceptance:
            Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition.t() | nil
        }

  defstruct [:after_submit, :shipping_address, :submit, :terms_of_service_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      after_submit: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition, :t},
      shipping_address: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition, :t},
      submit: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition, :t},
      terms_of_service_acceptance: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomTextPosition, :t}
    ]
  end
end
