defmodule Dhc.Stripe.PaymentPagesCheckoutSessionConsentCollection do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionConsentCollection
  """

  @type t :: %__MODULE__{
          payment_method_reuse_agreement:
            Dhc.Stripe.PaymentPagesCheckoutSessionPaymentMethodReuseAgreement.t() | nil,
          promotions: String.t() | nil,
          terms_of_service: String.t() | nil
        }

  defstruct [:payment_method_reuse_agreement, :promotions, :terms_of_service]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      payment_method_reuse_agreement:
        {Dhc.Stripe.PaymentPagesCheckoutSessionPaymentMethodReuseAgreement, :t},
      promotions: {:enum, ["auto", "none"]},
      terms_of_service: {:enum, ["none", "required"]}
    ]
  end
end
