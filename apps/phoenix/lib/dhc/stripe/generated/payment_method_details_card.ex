defmodule Dhc.Stripe.PaymentMethodDetailsCard do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCard
  """

  @type t :: %__MODULE__{
          amount_authorized: integer | nil,
          authorization_code: String.t() | nil,
          brand: String.t() | nil,
          capture_before: integer | nil,
          checks: Dhc.Stripe.PaymentMethodDetailsCardChecks.t() | nil,
          country: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          extended_authorization:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesExtendedAuthorizationExtendedAuthorization.t()
            | nil,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          incremental_authorization:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesIncrementalAuthorizationIncrementalAuthorization.t()
            | nil,
          installments: Dhc.Stripe.PaymentMethodDetailsCardInstallments.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil,
          multicapture:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceMulticapture.t()
            | nil,
          network: String.t() | nil,
          network_token: Dhc.Stripe.PaymentMethodDetailsCardNetworkToken.t() | nil,
          network_transaction_id: String.t() | nil,
          overcapture:
            Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesOvercaptureOvercapture.t()
            | nil,
          regulated_status: String.t() | nil,
          three_d_secure: Dhc.Stripe.ThreeDSecureDetailsCharge.t() | nil,
          transaction_link_id: String.t() | nil,
          wallet: Dhc.Stripe.PaymentMethodDetailsCardWallet.t() | nil
        }

  defstruct [
    :amount_authorized,
    :authorization_code,
    :brand,
    :capture_before,
    :checks,
    :country,
    :exp_month,
    :exp_year,
    :extended_authorization,
    :fingerprint,
    :funding,
    :incremental_authorization,
    :installments,
    :last4,
    :mandate,
    :multicapture,
    :network,
    :network_token,
    :network_transaction_id,
    :overcapture,
    :regulated_status,
    :three_d_secure,
    :transaction_link_id,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_authorized: :integer,
      authorization_code: :string,
      brand: :string,
      capture_before: {:integer, "unix-time"},
      checks: {Dhc.Stripe.PaymentMethodDetailsCardChecks, :t},
      country: :string,
      exp_month: :integer,
      exp_year: :integer,
      extended_authorization:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesExtendedAuthorizationExtendedAuthorization,
         :t},
      fingerprint: :string,
      funding: :string,
      incremental_authorization:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesIncrementalAuthorizationIncrementalAuthorization,
         :t},
      installments: {Dhc.Stripe.PaymentMethodDetailsCardInstallments, :t},
      last4: :string,
      mandate: :string,
      multicapture:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceMulticapture, :t},
      network: :string,
      network_token: {Dhc.Stripe.PaymentMethodDetailsCardNetworkToken, :t},
      network_transaction_id: :string,
      overcapture:
        {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesOvercaptureOvercapture,
         :t},
      regulated_status: {:enum, ["regulated", "unregulated"]},
      three_d_secure: {Dhc.Stripe.ThreeDSecureDetailsCharge, :t},
      transaction_link_id: :string,
      wallet: {Dhc.Stripe.PaymentMethodDetailsCardWallet, :t}
    ]
  end
end
