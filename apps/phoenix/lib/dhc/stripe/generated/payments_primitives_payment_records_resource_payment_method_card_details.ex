defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetails
  """

  @type t :: %__MODULE__{
          authorization_code: String.t() | nil,
          brand: String.t() | nil,
          capture_before: integer | nil,
          checks:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceChecks.t()
            | nil,
          country: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          installments:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallments.t()
            | nil,
          last4: String.t() | nil,
          network: String.t() | nil,
          network_advice_code: String.t() | nil,
          network_decline_code: String.t() | nil,
          network_token:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceNetworkToken.t()
            | nil,
          network_transaction_id: String.t() | nil,
          three_d_secure:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceThreeDSecure.t()
            | nil,
          wallet:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWallet.t()
            | nil
        }

  defstruct [
    :authorization_code,
    :brand,
    :capture_before,
    :checks,
    :country,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :installments,
    :last4,
    :network,
    :network_advice_code,
    :network_decline_code,
    :network_token,
    :network_transaction_id,
    :three_d_secure,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      authorization_code: :string,
      brand:
        {:enum,
         [
           "amex",
           "cartes_bancaires",
           "diners",
           "discover",
           "eftpos_au",
           "interac",
           "jcb",
           "link",
           "mastercard",
           "unionpay",
           "unknown",
           "visa"
         ]},
      capture_before: {:integer, "unix-time"},
      checks:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceChecks,
         :t},
      country: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: {:enum, ["credit", "debit", "prepaid", "unknown"]},
      installments:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallments,
         :t},
      last4: :string,
      network:
        {:enum,
         [
           "amex",
           "cartes_bancaires",
           "diners",
           "discover",
           "eftpos_au",
           "interac",
           "jcb",
           "link",
           "mastercard",
           "unionpay",
           "unknown",
           "visa"
         ]},
      network_advice_code: :string,
      network_decline_code: :string,
      network_token:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceNetworkToken,
         :t},
      network_transaction_id: :string,
      three_d_secure:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceThreeDSecure,
         :t},
      wallet:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWallet,
         :t}
    ]
  end
end
