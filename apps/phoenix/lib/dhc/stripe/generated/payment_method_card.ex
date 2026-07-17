defmodule Dhc.Stripe.PaymentMethodCard do
  @moduledoc """
  Provides struct and type for a PaymentMethodCard
  """

  @type t :: %__MODULE__{
          brand: String.t(),
          checks: Dhc.Stripe.PaymentMethodCardChecks.t() | nil,
          country: String.t() | nil,
          display_brand: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          fingerprint: String.t() | nil,
          funding: String.t(),
          generated_from: Dhc.Stripe.PaymentMethodCardGeneratedCard.t() | nil,
          last4: String.t(),
          networks: Dhc.Stripe.Networks.t() | nil,
          regulated_status: String.t() | nil,
          three_d_secure_usage: Dhc.Stripe.ThreeDSecureUsage.t() | nil,
          wallet: Dhc.Stripe.PaymentMethodCardWallet.t() | nil
        }

  defstruct [
    :brand,
    :checks,
    :country,
    :display_brand,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :generated_from,
    :last4,
    :networks,
    :regulated_status,
    :three_d_secure_usage,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      checks: {Dhc.Stripe.PaymentMethodCardChecks, :t},
      country: :string,
      display_brand: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      generated_from: {Dhc.Stripe.PaymentMethodCardGeneratedCard, :t},
      last4: :string,
      networks: {Dhc.Stripe.Networks, :t},
      regulated_status: {:enum, ["regulated", "unregulated"]},
      three_d_secure_usage: {Dhc.Stripe.ThreeDSecureUsage, :t},
      wallet: {Dhc.Stripe.PaymentMethodCardWallet, :t}
    ]
  end
end
