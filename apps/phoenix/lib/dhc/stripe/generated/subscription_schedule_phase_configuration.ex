defmodule Dhc.Stripe.SubscriptionSchedulePhaseConfiguration do
  @moduledoc """
  Provides struct and type for a SubscriptionSchedulePhaseConfiguration
  """

  @type t :: %__MODULE__{
          add_invoice_items: [Dhc.Stripe.SubscriptionScheduleAddInvoiceItem.t()],
          application_fee_percent: number | nil,
          automatic_tax: Dhc.Stripe.SchedulesPhaseAutomaticTax.t() | nil,
          billing_cycle_anchor: String.t() | nil,
          billing_thresholds: Dhc.Stripe.SubscriptionBillingThresholds.t() | nil,
          collection_method: String.t() | nil,
          currency: String.t(),
          default_payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          default_tax_rates: [Dhc.Stripe.TaxRate.t()] | nil,
          description: String.t() | nil,
          discounts: [Dhc.Stripe.StackableDiscountWithDiscountSettingsAndDiscountEnd.t()],
          end_date: integer,
          invoice_settings: Dhc.Stripe.InvoiceSettingSubscriptionSchedulePhaseSetting.t() | nil,
          items: [Dhc.Stripe.SubscriptionScheduleConfigurationItem.t()],
          metadata: map | nil,
          on_behalf_of: Dhc.Stripe.Account.t() | String.t() | nil,
          proration_behavior: String.t(),
          start_date: integer,
          transfer_data: Dhc.Stripe.SubscriptionTransferData.t() | nil,
          trial_end: integer | nil
        }

  defstruct [
    :add_invoice_items,
    :application_fee_percent,
    :automatic_tax,
    :billing_cycle_anchor,
    :billing_thresholds,
    :collection_method,
    :currency,
    :default_payment_method,
    :default_tax_rates,
    :description,
    :discounts,
    :end_date,
    :invoice_settings,
    :items,
    :metadata,
    :on_behalf_of,
    :proration_behavior,
    :start_date,
    :transfer_data,
    :trial_end
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      add_invoice_items: [{Dhc.Stripe.SubscriptionScheduleAddInvoiceItem, :t}],
      application_fee_percent: :number,
      automatic_tax: {Dhc.Stripe.SchedulesPhaseAutomaticTax, :t},
      billing_cycle_anchor: {:enum, ["automatic", "phase_start"]},
      billing_thresholds: {Dhc.Stripe.SubscriptionBillingThresholds, :t},
      collection_method: {:enum, ["charge_automatically", "send_invoice"]},
      currency: {:string, "currency"},
      default_payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      default_tax_rates: [{Dhc.Stripe.TaxRate, :t}],
      description: :string,
      discounts: [{Dhc.Stripe.StackableDiscountWithDiscountSettingsAndDiscountEnd, :t}],
      end_date: {:integer, "unix-time"},
      invoice_settings: {Dhc.Stripe.InvoiceSettingSubscriptionSchedulePhaseSetting, :t},
      items: [{Dhc.Stripe.SubscriptionScheduleConfigurationItem, :t}],
      metadata: :map,
      on_behalf_of: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]},
      start_date: {:integer, "unix-time"},
      transfer_data: {Dhc.Stripe.SubscriptionTransferData, :t},
      trial_end: {:integer, "unix-time"}
    ]
  end
end
