defmodule Dhc.Stripe.SetupIntentNextAction do
  @moduledoc """
  Provides struct and type for a SetupIntentNextAction
  """

  @type t :: %__MODULE__{
          blik_authorize: map | nil,
          cashapp_handle_redirect_or_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode.t() | nil,
          pix_display_qr_code: Dhc.Stripe.SetupIntentNextActionPixDisplayQrCode.t() | nil,
          redirect_to_url: Dhc.Stripe.SetupIntentNextActionRedirectToUrl.t() | nil,
          type: String.t(),
          upi_handle_redirect_or_display_qr_code:
            Dhc.Stripe.PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode.t() | nil,
          use_stripe_sdk: map | nil,
          verify_with_microdeposits:
            Dhc.Stripe.SetupIntentNextActionVerifyWithMicrodeposits.t() | nil
        }

  defstruct [
    :blik_authorize,
    :cashapp_handle_redirect_or_display_qr_code,
    :pix_display_qr_code,
    :redirect_to_url,
    :type,
    :upi_handle_redirect_or_display_qr_code,
    :use_stripe_sdk,
    :verify_with_microdeposits
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      blik_authorize: :map,
      cashapp_handle_redirect_or_display_qr_code:
        {Dhc.Stripe.PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode, :t},
      pix_display_qr_code: {Dhc.Stripe.SetupIntentNextActionPixDisplayQrCode, :t},
      redirect_to_url: {Dhc.Stripe.SetupIntentNextActionRedirectToUrl, :t},
      type: :string,
      upi_handle_redirect_or_display_qr_code:
        {Dhc.Stripe.PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode, :t},
      use_stripe_sdk: :map,
      verify_with_microdeposits: {Dhc.Stripe.SetupIntentNextActionVerifyWithMicrodeposits, :t}
    ]
  end
end
