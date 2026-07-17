defmodule Dhc.Stripe.PaymentLinksResourceCustomText do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceCustomText
  """

  @type t :: %__MODULE__{
          after_submit: Dhc.Stripe.PaymentLinksResourceCustomTextPosition.t() | nil,
          shipping_address: Dhc.Stripe.PaymentLinksResourceCustomTextPosition.t() | nil,
          submit: Dhc.Stripe.PaymentLinksResourceCustomTextPosition.t() | nil,
          terms_of_service_acceptance: Dhc.Stripe.PaymentLinksResourceCustomTextPosition.t() | nil
        }

  defstruct [:after_submit, :shipping_address, :submit, :terms_of_service_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      after_submit: {Dhc.Stripe.PaymentLinksResourceCustomTextPosition, :t},
      shipping_address: {Dhc.Stripe.PaymentLinksResourceCustomTextPosition, :t},
      submit: {Dhc.Stripe.PaymentLinksResourceCustomTextPosition, :t},
      terms_of_service_acceptance: {Dhc.Stripe.PaymentLinksResourceCustomTextPosition, :t}
    ]
  end
end
