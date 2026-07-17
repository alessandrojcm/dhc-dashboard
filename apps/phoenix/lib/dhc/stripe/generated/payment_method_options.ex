defmodule Dhc.Stripe.PaymentMethodOptions do
  @moduledoc """
  Provides struct and types for a PaymentMethodOptions
  """

  @type t :: %__MODULE__{
          acss_debit: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil,
          bancontact: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil,
          card: Dhc.Stripe.SubscriptionPaymentMethodOptionsParam.t() | String.t() | nil,
          customer_balance: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil,
          konbini: map | String.t() | nil,
          payto: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil,
          pix: Dhc.Stripe.SubscriptionPaymentMethodOptionsParam.t() | String.t() | nil,
          sepa_debit: map | String.t() | nil,
          upi: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil,
          us_bank_account: Dhc.Stripe.InvoicePaymentMethodOptionsParam.t() | String.t() | nil
        }

  defstruct [
    :acss_debit,
    :bancontact,
    :card,
    :customer_balance,
    :konbini,
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
      acss_debit: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]},
      bancontact: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]},
      card: {:union, [{Dhc.Stripe.SubscriptionPaymentMethodOptionsParam, :t}, const: ""]},
      customer_balance: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]},
      konbini: {:union, [:map, const: ""]},
      payto: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]},
      pix: {:union, [{Dhc.Stripe.SubscriptionPaymentMethodOptionsParam, :t}, const: ""]},
      sepa_debit: {:union, [:map, const: ""]},
      upi: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]},
      us_bank_account: {:union, [{Dhc.Stripe.InvoicePaymentMethodOptionsParam, :t}, const: ""]}
    ]
  end
end
