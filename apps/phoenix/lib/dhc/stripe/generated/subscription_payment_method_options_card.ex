defmodule Dhc.Stripe.SubscriptionPaymentMethodOptionsCard do
  @moduledoc """
  Provides struct and type for a SubscriptionPaymentMethodOptionsCard
  """

  @type t :: %__MODULE__{
          mandate_options: Dhc.Stripe.InvoiceMandateOptionsCard.t() | nil,
          network: String.t() | nil,
          request_three_d_secure: String.t() | nil
        }

  defstruct [:mandate_options, :network, :request_three_d_secure]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mandate_options: {Dhc.Stripe.InvoiceMandateOptionsCard, :t},
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
