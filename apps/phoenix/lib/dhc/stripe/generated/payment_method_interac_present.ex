defmodule Dhc.Stripe.PaymentMethodInteracPresent do
  @moduledoc """
  Provides struct and type for a PaymentMethodInteracPresent
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          cardholder_name: String.t() | nil,
          country: String.t() | nil,
          description: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          issuer: String.t() | nil,
          last4: String.t() | nil,
          networks: Dhc.Stripe.PaymentMethodCardPresentNetworks.t() | nil,
          preferred_locales: [String.t()] | nil,
          read_method: String.t() | nil
        }

  defstruct [
    :brand,
    :cardholder_name,
    :country,
    :description,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :issuer,
    :last4,
    :networks,
    :preferred_locales,
    :read_method
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
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      issuer: :string,
      last4: :string,
      networks: {Dhc.Stripe.PaymentMethodCardPresentNetworks, :t},
      preferred_locales: [:string],
      read_method:
        {:enum,
         [
           "contact_emv",
           "contactless_emv",
           "contactless_magstripe_mode",
           "magnetic_stripe_fallback",
           "magnetic_stripe_track2"
         ]}
    ]
  end
end
