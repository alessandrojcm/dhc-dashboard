defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          acss_debit:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsAcssDebit.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          affirm:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsAffirm.t()
            | nil,
          afterpay_clearpay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsAfterpayClearpay.t()
            | nil,
          alipay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsAlipay.t()
            | nil,
          alma:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsAlma.t()
            | nil,
          amazon_pay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsAmazonPay.t()
            | nil,
          au_becs_debit:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsAuBecsDebit.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          bacs_debit:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsBacsDebit.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          bancontact:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsBancontact.t()
            | nil,
          billie:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsBillie.t()
            | nil,
          bizum: map | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          blik:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsBlik.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          boleto:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsBoleto.t()
            | nil,
          card:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsCard.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          card_present:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsCardPresent.t()
            | nil,
          cashapp:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsCashapp.t()
            | nil,
          crypto:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsCrypto.t()
            | nil,
          customer_balance:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsCustomerBalance.t()
            | nil,
          eps:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsEps.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          fpx:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsFpx.t()
            | nil,
          giropay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsGiropay.t()
            | nil,
          grabpay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsGrabpay.t()
            | nil,
          ideal:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsIdeal.t()
            | nil,
          interac_present:
            map | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          kakao_pay:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKakaoPayPaymentMethodOptions.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          klarna:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsKlarna.t()
            | nil,
          konbini:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsKonbini.t()
            | nil,
          kr_card:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsKrCard.t()
            | nil,
          link:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsLink.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          mb_way:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsMbWay.t()
            | nil,
          mobilepay:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsMobilepay.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          multibanco:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsMultibanco.t()
            | nil,
          naver_pay:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsNaverPayPaymentMethodOptions.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          nz_bank_account:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsNzBankAccount.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          oxxo:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsOxxo.t()
            | nil,
          p2_4:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsP24.t()
            | nil,
          pay_by_bank:
            map | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t() | nil,
          payco:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsPaycoPaymentMethodOptions.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          paynow:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsPaynow.t()
            | nil,
          paypal:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsPaypal.t()
            | nil,
          payto:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsPayto.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          pix:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsPix.t()
            | nil,
          promptpay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsPromptpay.t()
            | nil,
          revolut_pay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsRevolutPay.t()
            | nil,
          samsung_pay:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsSamsungPayPaymentMethodOptions.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          satispay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsSatispay.t()
            | nil,
          scalapay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsScalapay.t()
            | nil,
          sepa_debit:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsSepaDebit.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          sofort:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsSofort.t()
            | nil,
          sunbit:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsSunbit.t()
            | nil,
          swish:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsSwish.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          twint:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsTwint.t()
            | nil,
          upi:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsUpi.t()
            | nil,
          us_bank_account:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsUsBankAccount.t()
            | Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | nil,
          wechat_pay:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsWechatPay.t()
            | nil,
          zip:
            Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient.t()
            | Dhc.Stripe.PaymentMethodOptionsZip.t()
            | nil
        }

  defstruct [
    :acss_debit,
    :affirm,
    :afterpay_clearpay,
    :alipay,
    :alma,
    :amazon_pay,
    :au_becs_debit,
    :bacs_debit,
    :bancontact,
    :billie,
    :bizum,
    :blik,
    :boleto,
    :card,
    :card_present,
    :cashapp,
    :crypto,
    :customer_balance,
    :eps,
    :fpx,
    :giropay,
    :grabpay,
    :ideal,
    :interac_present,
    :kakao_pay,
    :klarna,
    :konbini,
    :kr_card,
    :link,
    :mb_way,
    :mobilepay,
    :multibanco,
    :naver_pay,
    :nz_bank_account,
    :oxxo,
    :p2_4,
    :pay_by_bank,
    :payco,
    :paynow,
    :paypal,
    :payto,
    :pix,
    :promptpay,
    :revolut_pay,
    :samsung_pay,
    :satispay,
    :scalapay,
    :sepa_debit,
    :sofort,
    :sunbit,
    :swish,
    :twint,
    :upi,
    :us_bank_account,
    :wechat_pay,
    :zip
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      acss_debit:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsAcssDebit, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      affirm:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsAffirm, :t}
         ]},
      afterpay_clearpay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsAfterpayClearpay, :t}
         ]},
      alipay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsAlipay, :t}
         ]},
      alma:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsAlma, :t}
         ]},
      amazon_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsAmazonPay, :t}
         ]},
      au_becs_debit:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsAuBecsDebit, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      bacs_debit:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsBacsDebit, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      bancontact:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsBancontact, :t}
         ]},
      billie:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsBillie, :t}
         ]},
      bizum:
        {:union, [:map, {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      blik:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsBlik, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      boleto:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsBoleto, :t}
         ]},
      card:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsCard, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      card_present:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsCardPresent, :t}
         ]},
      cashapp:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsCashapp, :t}
         ]},
      crypto:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsCrypto, :t}
         ]},
      customer_balance:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsCustomerBalance, :t}
         ]},
      eps:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsEps, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      fpx:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsFpx, :t}
         ]},
      giropay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsGiropay, :t}
         ]},
      grabpay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsGrabpay, :t}
         ]},
      ideal:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsIdeal, :t}
         ]},
      interac_present:
        {:union, [:map, {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      kakao_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKakaoPayPaymentMethodOptions, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      klarna:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsKlarna, :t}
         ]},
      konbini:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsKonbini, :t}
         ]},
      kr_card:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsKrCard, :t}
         ]},
      link:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsLink, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      mb_way:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsMbWay, :t}
         ]},
      mobilepay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsMobilepay, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      multibanco:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsMultibanco, :t}
         ]},
      naver_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsNaverPayPaymentMethodOptions, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      nz_bank_account:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsNzBankAccount, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      oxxo:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsOxxo, :t}
         ]},
      p2_4:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsP24, :t}
         ]},
      pay_by_bank:
        {:union, [:map, {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}]},
      payco:
        {:union,
         [
           {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsPaycoPaymentMethodOptions, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      paynow:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsPaynow, :t}
         ]},
      paypal:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsPaypal, :t}
         ]},
      payto:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsPayto, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      pix:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsPix, :t}
         ]},
      promptpay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsPromptpay, :t}
         ]},
      revolut_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsRevolutPay, :t}
         ]},
      samsung_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsSamsungPayPaymentMethodOptions, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      satispay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsSatispay, :t}
         ]},
      scalapay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsScalapay, :t}
         ]},
      sepa_debit:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsSepaDebit, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      sofort:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsSofort, :t}
         ]},
      sunbit:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsSunbit, :t}
         ]},
      swish:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsSwish, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      twint:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsTwint, :t}
         ]},
      upi:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsUpi, :t}
         ]},
      us_bank_account:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsUsBankAccount, :t},
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t}
         ]},
      wechat_pay:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsWechatPay, :t}
         ]},
      zip:
        {:union,
         [
           {Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient, :t},
           {Dhc.Stripe.PaymentMethodOptionsZip, :t}
         ]}
    ]
  end
end
