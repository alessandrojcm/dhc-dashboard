defmodule Dhc.Stripe.PaymentIntentNextAction do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextAction
  """

  @type t :: %__MODULE__{
          alipay_handle_redirect:
            Dhc.Stripe.PaymentIntentNextActionAlipayHandleRedirect.t() | nil,
          blik_authorize: map | nil,
          boleto_display_details: Dhc.Stripe.PaymentIntentNextActionBoleto.t() | nil,
          card_await_notification:
            Dhc.Stripe.PaymentIntentNextActionCardAwaitNotification.t() | nil,
          cashapp_handle_redirect_or_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode.t() | nil,
          display_bank_transfer_instructions:
            Dhc.Stripe.PaymentIntentNextActionDisplayBankTransferInstructions.t() | nil,
          klarna_display_qr_code: Dhc.Stripe.PaymentIntentNextActionKlarnaDisplayQrCode.t() | nil,
          konbini_display_details: Dhc.Stripe.PaymentIntentNextActionKonbini.t() | nil,
          multibanco_display_details:
            Dhc.Stripe.PaymentIntentNextActionDisplayMultibancoDetails.t() | nil,
          oxxo_display_details: Dhc.Stripe.PaymentIntentNextActionDisplayOxxoDetails.t() | nil,
          paynow_display_qr_code: Dhc.Stripe.PaymentIntentNextActionPaynowDisplayQrCode.t() | nil,
          pix_display_qr_code: Dhc.Stripe.PaymentIntentNextActionPixDisplayQrCode.t() | nil,
          promptpay_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionPromptpayDisplayQrCode.t() | nil,
          redirect_to_url: Dhc.Stripe.PaymentIntentNextActionRedirectToUrl.t() | nil,
          swish_handle_redirect_or_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionSwishHandleRedirectOrDisplayQrCode.t() | nil,
          type: String.t(),
          upi_handle_redirect_or_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode.t() | nil,
          use_stripe_sdk: map | nil,
          verify_with_microdeposits:
            Dhc.Stripe.PaymentIntentNextActionVerifyWithMicrodeposits.t() | nil,
          wechat_pay_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionWechatPayDisplayQrCode.t() | nil,
          wechat_pay_redirect_to_android_app:
            Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToAndroidApp.t() | nil,
          wechat_pay_redirect_to_ios_app:
            Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToIosApp.t() | nil
        }

  defstruct [
    :alipay_handle_redirect,
    :blik_authorize,
    :boleto_display_details,
    :card_await_notification,
    :cashapp_handle_redirect_or_display_qr_code,
    :display_bank_transfer_instructions,
    :klarna_display_qr_code,
    :konbini_display_details,
    :multibanco_display_details,
    :oxxo_display_details,
    :paynow_display_qr_code,
    :pix_display_qr_code,
    :promptpay_display_qr_code,
    :redirect_to_url,
    :swish_handle_redirect_or_display_qr_code,
    :type,
    :upi_handle_redirect_or_display_qr_code,
    :use_stripe_sdk,
    :verify_with_microdeposits,
    :wechat_pay_display_qr_code,
    :wechat_pay_redirect_to_android_app,
    :wechat_pay_redirect_to_ios_app
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      alipay_handle_redirect: {Dhc.Stripe.PaymentIntentNextActionAlipayHandleRedirect, :t},
      blik_authorize: :map,
      boleto_display_details: {Dhc.Stripe.PaymentIntentNextActionBoleto, :t},
      card_await_notification: {Dhc.Stripe.PaymentIntentNextActionCardAwaitNotification, :t},
      cashapp_handle_redirect_or_display_qr_code:
        {Dhc.Stripe.PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode, :t},
      display_bank_transfer_instructions:
        {Dhc.Stripe.PaymentIntentNextActionDisplayBankTransferInstructions, :t},
      klarna_display_qr_code: {Dhc.Stripe.PaymentIntentNextActionKlarnaDisplayQrCode, :t},
      konbini_display_details: {Dhc.Stripe.PaymentIntentNextActionKonbini, :t},
      multibanco_display_details:
        {Dhc.Stripe.PaymentIntentNextActionDisplayMultibancoDetails, :t},
      oxxo_display_details: {Dhc.Stripe.PaymentIntentNextActionDisplayOxxoDetails, :t},
      paynow_display_qr_code: {Dhc.Stripe.PaymentIntentNextActionPaynowDisplayQrCode, :t},
      pix_display_qr_code: {Dhc.Stripe.PaymentIntentNextActionPixDisplayQrCode, :t},
      promptpay_display_qr_code: {Dhc.Stripe.PaymentIntentNextActionPromptpayDisplayQrCode, :t},
      redirect_to_url: {Dhc.Stripe.PaymentIntentNextActionRedirectToUrl, :t},
      swish_handle_redirect_or_display_qr_code:
        {Dhc.Stripe.PaymentIntentNextActionSwishHandleRedirectOrDisplayQrCode, :t},
      type: :string,
      upi_handle_redirect_or_display_qr_code:
        {Dhc.Stripe.PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode, :t},
      use_stripe_sdk: :map,
      verify_with_microdeposits: {Dhc.Stripe.PaymentIntentNextActionVerifyWithMicrodeposits, :t},
      wechat_pay_display_qr_code: {Dhc.Stripe.PaymentIntentNextActionWechatPayDisplayQrCode, :t},
      wechat_pay_redirect_to_android_app:
        {Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToAndroidApp, :t},
      wechat_pay_redirect_to_ios_app:
        {Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToIosApp, :t}
    ]
  end
end
