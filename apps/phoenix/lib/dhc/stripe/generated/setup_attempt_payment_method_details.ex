defmodule Dhc.Stripe.SetupAttemptPaymentMethodDetails do
  @moduledoc """
  Provides struct and type for a SetupAttemptPaymentMethodDetails
  """

  @type t :: %__MODULE__{
          acss_debit: map | nil,
          amazon_pay: map | nil,
          au_becs_debit: map | nil,
          bacs_debit: map | nil,
          bancontact: Dhc.Stripe.SetupAttemptPaymentMethodDetailsBancontact.t() | nil,
          boleto: map | nil,
          card: Dhc.Stripe.SetupAttemptPaymentMethodDetailsCard.t() | nil,
          card_present: Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardPresent.t() | nil,
          cashapp: map | nil,
          ideal: Dhc.Stripe.SetupAttemptPaymentMethodDetailsIdeal.t() | nil,
          kakao_pay: map | nil,
          klarna: map | nil,
          kr_card: map | nil,
          link: map | nil,
          naver_pay: Dhc.Stripe.SetupAttemptPaymentMethodDetailsNaverPay.t() | nil,
          nz_bank_account: map | nil,
          paypal: map | nil,
          payto: map | nil,
          pix: Dhc.Stripe.SetupAttemptPaymentMethodDetailsPix.t() | nil,
          revolut_pay: map | nil,
          satispay: map | nil,
          sepa_debit: map | nil,
          sofort: Dhc.Stripe.SetupAttemptPaymentMethodDetailsSofort.t() | nil,
          twint: map | nil,
          type: String.t(),
          upi: map | nil,
          us_bank_account: map | nil
        }

  defstruct [
    :acss_debit,
    :amazon_pay,
    :au_becs_debit,
    :bacs_debit,
    :bancontact,
    :boleto,
    :card,
    :card_present,
    :cashapp,
    :ideal,
    :kakao_pay,
    :klarna,
    :kr_card,
    :link,
    :naver_pay,
    :nz_bank_account,
    :paypal,
    :payto,
    :pix,
    :revolut_pay,
    :satispay,
    :sepa_debit,
    :sofort,
    :twint,
    :type,
    :upi,
    :us_bank_account
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      acss_debit: :map,
      amazon_pay: :map,
      au_becs_debit: :map,
      bacs_debit: :map,
      bancontact: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsBancontact, :t},
      boleto: :map,
      card: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsCard, :t},
      card_present: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardPresent, :t},
      cashapp: :map,
      ideal: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsIdeal, :t},
      kakao_pay: :map,
      klarna: :map,
      kr_card: :map,
      link: :map,
      naver_pay: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsNaverPay, :t},
      nz_bank_account: :map,
      paypal: :map,
      payto: :map,
      pix: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsPix, :t},
      revolut_pay: :map,
      satispay: :map,
      sepa_debit: :map,
      sofort: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsSofort, :t},
      twint: :map,
      type: :string,
      upi: :map,
      us_bank_account: :map
    ]
  end
end
