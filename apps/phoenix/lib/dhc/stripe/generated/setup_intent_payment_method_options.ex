defmodule Dhc.Stripe.SetupIntentPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          acss_debit:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsAcssDebit.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          amazon_pay:
            map | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          bacs_debit:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsBacsDebit.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          bizum: map | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          card:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsCard.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          card_present:
            map | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          klarna:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsKlarna.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          link: map | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          paypal:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsPaypal.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          payto:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsPayto.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          pix:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsPix.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          sepa_debit:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsSepaDebit.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          upi:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsUpi.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          us_bank_account:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsUsBankAccount.t()
            | Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil
        }

  defstruct [
    :acss_debit,
    :amazon_pay,
    :bacs_debit,
    :bizum,
    :card,
    :card_present,
    :klarna,
    :link,
    :paypal,
    :payto,
    :pix,
    :sepa_debit,
    :upi,
    :us_bank_account
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      acss_debit:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsAcssDebit, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      amazon_pay:
        {:union, [:map, {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      bacs_debit:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsBacsDebit, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      bizum: {:union, [:map, {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      card:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsCard, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      card_present:
        {:union, [:map, {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      klarna:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsKlarna, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      link: {:union, [:map, {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      paypal:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsPaypal, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      payto:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsPayto, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      pix:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsPix, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      sepa_debit:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsSepaDebit, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      upi:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsUpi, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      us_bank_account:
        {:union,
         [
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsUsBankAccount, :t},
           {Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]}
    ]
  end
end
