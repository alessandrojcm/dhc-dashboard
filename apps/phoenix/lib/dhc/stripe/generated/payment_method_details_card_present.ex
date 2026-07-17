defmodule Dhc.Stripe.PaymentMethodDetailsCardPresent do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCardPresent
  """

  @type t :: %__MODULE__{
          amount_authorized: integer | nil,
          brand: String.t() | nil,
          brand_product: String.t() | nil,
          capture_before: integer | nil,
          cardholder_name: String.t() | nil,
          country: String.t() | nil,
          description: String.t() | nil,
          emv_auth_data: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          generated_card: String.t() | nil,
          incremental_authorization_supported: boolean,
          issuer: String.t() | nil,
          last4: String.t() | nil,
          location: String.t() | nil,
          network: String.t() | nil,
          network_transaction_id: String.t() | nil,
          offline: Dhc.Stripe.PaymentMethodDetailsCardPresentOffline.t() | nil,
          overcapture_supported: boolean,
          preferred_locales: [String.t()] | nil,
          read_method: String.t() | nil,
          reader: String.t() | nil,
          receipt: Dhc.Stripe.PaymentMethodDetailsCardPresentReceipt.t() | nil,
          wallet: Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentCommonWallet.t() | nil
        }

  defstruct [
    :amount_authorized,
    :brand,
    :brand_product,
    :capture_before,
    :cardholder_name,
    :country,
    :description,
    :emv_auth_data,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :generated_card,
    :incremental_authorization_supported,
    :issuer,
    :last4,
    :location,
    :network,
    :network_transaction_id,
    :offline,
    :overcapture_supported,
    :preferred_locales,
    :read_method,
    :reader,
    :receipt,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_authorized: :integer,
      brand: :string,
      brand_product: :string,
      capture_before: {:integer, "unix-time"},
      cardholder_name: :string,
      country: :string,
      description: :string,
      emv_auth_data: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      generated_card: :string,
      incremental_authorization_supported: :boolean,
      issuer: :string,
      last4: :string,
      location: :string,
      network: :string,
      network_transaction_id: :string,
      offline: {Dhc.Stripe.PaymentMethodDetailsCardPresentOffline, :t},
      overcapture_supported: :boolean,
      preferred_locales: [:string],
      read_method:
        {:enum,
         [
           "contact_emv",
           "contactless_emv",
           "contactless_magstripe_mode",
           "magnetic_stripe_fallback",
           "magnetic_stripe_track2"
         ]},
      reader: :string,
      receipt: {Dhc.Stripe.PaymentMethodDetailsCardPresentReceipt, :t},
      wallet: {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardPresentCommonWallet, :t}
    ]
  end
end
