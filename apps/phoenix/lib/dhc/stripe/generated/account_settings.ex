defmodule Dhc.Stripe.AccountSettings do
  @moduledoc """
  Provides struct and type for a AccountSettings
  """

  @type t :: %__MODULE__{
          bacs_debit_payments: Dhc.Stripe.AccountBacsDebitPaymentsSettings.t() | nil,
          branding: Dhc.Stripe.AccountBrandingSettings.t(),
          card_issuing: Dhc.Stripe.AccountCardIssuingSettings.t() | nil,
          card_payments: Dhc.Stripe.AccountCardPaymentsSettings.t(),
          dashboard: Dhc.Stripe.AccountDashboardSettings.t(),
          invoices: Dhc.Stripe.AccountInvoicesSettings.t() | nil,
          payments: Dhc.Stripe.AccountPaymentsSettings.t(),
          payouts: Dhc.Stripe.AccountPayoutSettings.t() | nil,
          sepa_debit_payments: Dhc.Stripe.AccountSepaDebitPaymentsSettings.t() | nil,
          treasury: Dhc.Stripe.AccountTreasurySettings.t() | nil
        }

  defstruct [
    :bacs_debit_payments,
    :branding,
    :card_issuing,
    :card_payments,
    :dashboard,
    :invoices,
    :payments,
    :payouts,
    :sepa_debit_payments,
    :treasury
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bacs_debit_payments: {Dhc.Stripe.AccountBacsDebitPaymentsSettings, :t},
      branding: {Dhc.Stripe.AccountBrandingSettings, :t},
      card_issuing: {Dhc.Stripe.AccountCardIssuingSettings, :t},
      card_payments: {Dhc.Stripe.AccountCardPaymentsSettings, :t},
      dashboard: {Dhc.Stripe.AccountDashboardSettings, :t},
      invoices: {Dhc.Stripe.AccountInvoicesSettings, :t},
      payments: {Dhc.Stripe.AccountPaymentsSettings, :t},
      payouts: {Dhc.Stripe.AccountPayoutSettings, :t},
      sepa_debit_payments: {Dhc.Stripe.AccountSepaDebitPaymentsSettings, :t},
      treasury: {Dhc.Stripe.AccountTreasurySettings, :t}
    ]
  end
end
