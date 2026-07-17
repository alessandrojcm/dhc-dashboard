defmodule Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettings do
  @moduledoc """
  Provides struct and type for a SubscriptionSchedulesResourceDefaultSettings
  """

  @type t :: %__MODULE__{
          application_fee_percent: number | nil,
          automatic_tax:
            Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettingsAutomaticTax.t() | nil,
          billing_cycle_anchor: String.t(),
          billing_thresholds: Dhc.Stripe.SubscriptionBillingThresholds.t() | nil,
          collection_method: String.t() | nil,
          default_payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          description: String.t() | nil,
          invoice_settings: Dhc.Stripe.InvoiceSettingSubscriptionScheduleSetting.t(),
          on_behalf_of: Dhc.Stripe.Account.t() | String.t() | nil,
          transfer_data: Dhc.Stripe.SubscriptionTransferData.t() | nil
        }

  defstruct [
    :application_fee_percent,
    :automatic_tax,
    :billing_cycle_anchor,
    :billing_thresholds,
    :collection_method,
    :default_payment_method,
    :description,
    :invoice_settings,
    :on_behalf_of,
    :transfer_data
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application_fee_percent: :number,
      automatic_tax: {Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettingsAutomaticTax, :t},
      billing_cycle_anchor: {:enum, ["automatic", "phase_start"]},
      billing_thresholds: {Dhc.Stripe.SubscriptionBillingThresholds, :t},
      collection_method: {:enum, ["charge_automatically", "send_invoice"]},
      default_payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      description: :string,
      invoice_settings: {Dhc.Stripe.InvoiceSettingSubscriptionScheduleSetting, :t},
      on_behalf_of: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      transfer_data: {Dhc.Stripe.SubscriptionTransferData, :t}
    ]
  end
end
