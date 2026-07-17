defmodule Dhc.Stripe.MandatePaymentMethodDetails do
  @moduledoc """
  Provides struct and type for a MandatePaymentMethodDetails
  """

  @type t :: %__MODULE__{
          acss_debit: Dhc.Stripe.MandateAcssDebit.t() | nil,
          amazon_pay: map | nil,
          au_becs_debit: Dhc.Stripe.MandateAuBecsDebit.t() | nil,
          bacs_debit: Dhc.Stripe.MandateBacsDebit.t() | nil,
          card: map | nil,
          cashapp: map | nil,
          kakao_pay: map | nil,
          klarna: map | nil,
          kr_card: map | nil,
          link: map | nil,
          naver_pay: map | nil,
          nz_bank_account: map | nil,
          paypal: Dhc.Stripe.MandatePaypal.t() | nil,
          payto: Dhc.Stripe.MandatePayto.t() | nil,
          pix: Dhc.Stripe.MandatePix.t() | nil,
          revolut_pay: map | nil,
          sepa_debit: Dhc.Stripe.MandateSepaDebit.t() | nil,
          twint: map | nil,
          type: String.t(),
          upi: Dhc.Stripe.MandateUpi.t() | nil,
          us_bank_account: Dhc.Stripe.MandateUsBankAccount.t() | nil
        }

  defstruct [
    :acss_debit,
    :amazon_pay,
    :au_becs_debit,
    :bacs_debit,
    :card,
    :cashapp,
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
    :sepa_debit,
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
      acss_debit: {Dhc.Stripe.MandateAcssDebit, :t},
      amazon_pay: :map,
      au_becs_debit: {Dhc.Stripe.MandateAuBecsDebit, :t},
      bacs_debit: {Dhc.Stripe.MandateBacsDebit, :t},
      card: :map,
      cashapp: :map,
      kakao_pay: :map,
      klarna: :map,
      kr_card: :map,
      link: :map,
      naver_pay: :map,
      nz_bank_account: :map,
      paypal: {Dhc.Stripe.MandatePaypal, :t},
      payto: {Dhc.Stripe.MandatePayto, :t},
      pix: {Dhc.Stripe.MandatePix, :t},
      revolut_pay: :map,
      sepa_debit: {Dhc.Stripe.MandateSepaDebit, :t},
      twint: :map,
      type: :string,
      upi: {Dhc.Stripe.MandateUpi, :t},
      us_bank_account: {Dhc.Stripe.MandateUsBankAccount, :t}
    ]
  end
end
