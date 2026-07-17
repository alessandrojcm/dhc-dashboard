defmodule Dhc.Stripe.PaymentMethodDetailsInteracPresent do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsInteracPresent
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          cardholder_name: String.t() | nil,
          country: String.t() | nil,
          description: String.t() | nil,
          emv_auth_data: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          generated_card: String.t() | nil,
          issuer: String.t() | nil,
          last4: String.t() | nil,
          location: String.t() | nil,
          network: String.t() | nil,
          network_transaction_id: String.t() | nil,
          preferred_locales: [String.t()] | nil,
          read_method: String.t() | nil,
          reader: String.t() | nil,
          receipt: Dhc.Stripe.PaymentMethodDetailsInteracPresentReceipt.t() | nil
        }

  defstruct [
    :brand,
    :cardholder_name,
    :country,
    :description,
    :emv_auth_data,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :generated_card,
    :issuer,
    :last4,
    :location,
    :network,
    :network_transaction_id,
    :preferred_locales,
    :read_method,
    :reader,
    :receipt
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      cardholder_name: :string,
      country: :string,
      description: :string,
      emv_auth_data: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      generated_card: :string,
      issuer: :string,
      last4: :string,
      location: :string,
      network: :string,
      network_transaction_id: :string,
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
      receipt: {Dhc.Stripe.PaymentMethodDetailsInteracPresentReceipt, :t}
    ]
  end
end
