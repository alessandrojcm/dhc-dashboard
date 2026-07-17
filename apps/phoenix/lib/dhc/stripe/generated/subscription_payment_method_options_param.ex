defmodule Dhc.Stripe.SubscriptionPaymentMethodOptionsParam do
  @moduledoc """
  Provides struct and types for a SubscriptionPaymentMethodOptionsParam
  """

  @type t :: %__MODULE__{
          expires_after_seconds: integer | nil,
          mandate_options:
            Dhc.Stripe.MandateOptionsParam.t()
            | Dhc.Stripe.SubscriptionPaymentMethodOptionsMandateOptionsParam.t()
            | nil,
          network: String.t() | nil,
          request_three_d_secure: String.t() | nil
        }

  defstruct [:expires_after_seconds, :mandate_options, :network, :request_three_d_secure]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      expires_after_seconds: :integer,
      mandate_options:
        {:union,
         [
           {Dhc.Stripe.MandateOptionsParam, :t},
           {Dhc.Stripe.SubscriptionPaymentMethodOptionsMandateOptionsParam, :t}
         ]},
      network:
        {:enum,
         [
           "amex",
           "cartes_bancaires",
           "diners",
           "discover",
           "eftpos_au",
           "girocard",
           "interac",
           "jcb",
           "link",
           "mastercard",
           "unionpay",
           "unknown",
           "visa"
         ]},
      request_three_d_secure: {:enum, ["any", "automatic", "challenge"]}
    ]
  end
end
