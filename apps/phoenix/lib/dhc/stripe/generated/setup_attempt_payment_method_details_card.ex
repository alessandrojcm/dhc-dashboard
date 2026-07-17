defmodule Dhc.Stripe.SetupAttemptPaymentMethodDetailsCard do
  @moduledoc """
  Provides struct and type for a SetupAttemptPaymentMethodDetailsCard
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          checks: Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardChecks.t() | nil,
          country: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          last4: String.t() | nil,
          network: String.t() | nil,
          three_d_secure: Dhc.Stripe.ThreeDSecureDetails.t() | nil,
          wallet: Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardWallet.t() | nil
        }

  defstruct [
    :brand,
    :checks,
    :country,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :last4,
    :network,
    :three_d_secure,
    :wallet
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      checks: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardChecks, :t},
      country: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      last4: :string,
      network: :string,
      three_d_secure: {Dhc.Stripe.ThreeDSecureDetails, :t},
      wallet: {Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardWallet, :t}
    ]
  end
end
