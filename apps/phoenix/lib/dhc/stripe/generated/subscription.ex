defmodule Dhc.Stripe.Subscription do
  @moduledoc """
  Provides struct and type for a Subscription
  """

  @type t :: %__MODULE__{
          application:
            Dhc.Stripe.Application.t() | Dhc.Stripe.DeletedApplication.t() | String.t() | nil,
          application_fee_percent: number | nil,
          automatic_tax: Dhc.Stripe.SubscriptionAutomaticTax.t(),
          billing_cycle_anchor: integer,
          billing_cycle_anchor_config:
            Dhc.Stripe.SubscriptionsResourceBillingCycleAnchorConfig.t() | nil,
          billing_mode: Dhc.Stripe.SubscriptionsResourceBillingMode.t(),
          billing_schedules: [Dhc.Stripe.SubscriptionsResourceBillingSchedules.t()],
          billing_thresholds: Dhc.Stripe.SubscriptionBillingThresholds.t() | nil,
          cancel_at: integer | nil,
          cancel_at_period_end: boolean,
          canceled_at: integer | nil,
          cancellation_details: Dhc.Stripe.CancellationDetails.t() | nil,
          collection_method: String.t(),
          created: integer,
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t(),
          customer_account: String.t() | nil,
          days_until_due: integer | nil,
          default_payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          default_source:
            Dhc.Stripe.BankAccount.t()
            | Dhc.Stripe.Card.t()
            | Dhc.Stripe.Source.t()
            | String.t()
            | nil,
          default_tax_rates: [Dhc.Stripe.TaxRate.t()] | nil,
          description: String.t() | nil,
          discounts: [Dhc.Stripe.Discount.t() | String.t()],
          ended_at: integer | nil,
          id: String.t(),
          invoice_settings: Dhc.Stripe.SubscriptionsResourceSubscriptionInvoiceSettings.t(),
          items: Dhc.Stripe.SubscriptionItemList.t(),
          latest_invoice: Dhc.Stripe.Invoice.t() | String.t() | nil,
          livemode: boolean,
          managed_payments: Dhc.Stripe.SmorResourceManagedPayments.t() | nil,
          metadata: map,
          next_pending_invoice_item_invoice: integer | nil,
          object: String.t(),
          on_behalf_of: Dhc.Stripe.Account.t() | String.t() | nil,
          pause_collection: Dhc.Stripe.SubscriptionsResourcePauseCollection.t() | nil,
          payment_settings: Dhc.Stripe.SubscriptionsResourcePaymentSettings.t() | nil,
          pending_invoice_item_interval:
            Dhc.Stripe.SubscriptionPendingInvoiceItemInterval.t() | nil,
          pending_setup_intent: Dhc.Stripe.SetupIntent.t() | String.t() | nil,
          pending_update: Dhc.Stripe.SubscriptionsResourcePendingUpdate.t() | nil,
          presentment_details:
            Dhc.Stripe.SubscriptionsResourceSubscriptionPresentmentDetails.t() | nil,
          schedule: Dhc.Stripe.SubscriptionSchedule.t() | String.t() | nil,
          start_date: integer,
          status: String.t(),
          test_clock: Dhc.Stripe.TestHelpersTestClock.t() | String.t() | nil,
          transfer_data: Dhc.Stripe.SubscriptionTransferData.t() | nil,
          trial_end: integer | nil,
          trial_settings: Dhc.Stripe.SubscriptionsResourceTrialSettingsTrialSettings.t() | nil,
          trial_start: integer | nil
        }

  defstruct [
    :application,
    :application_fee_percent,
    :automatic_tax,
    :billing_cycle_anchor,
    :billing_cycle_anchor_config,
    :billing_mode,
    :billing_schedules,
    :billing_thresholds,
    :cancel_at,
    :cancel_at_period_end,
    :canceled_at,
    :cancellation_details,
    :collection_method,
    :created,
    :currency,
    :customer,
    :customer_account,
    :days_until_due,
    :default_payment_method,
    :default_source,
    :default_tax_rates,
    :description,
    :discounts,
    :ended_at,
    :id,
    :invoice_settings,
    :items,
    :latest_invoice,
    :livemode,
    :managed_payments,
    :metadata,
    :next_pending_invoice_item_invoice,
    :object,
    :on_behalf_of,
    :pause_collection,
    :payment_settings,
    :pending_invoice_item_interval,
    :pending_setup_intent,
    :pending_update,
    :presentment_details,
    :schedule,
    :start_date,
    :status,
    :test_clock,
    :transfer_data,
    :trial_end,
    :trial_settings,
    :trial_start
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application:
        {:union, [:string, {Dhc.Stripe.Application, :t}, {Dhc.Stripe.DeletedApplication, :t}]},
      application_fee_percent: :number,
      automatic_tax: {Dhc.Stripe.SubscriptionAutomaticTax, :t},
      billing_cycle_anchor: {:integer, "unix-time"},
      billing_cycle_anchor_config: {Dhc.Stripe.SubscriptionsResourceBillingCycleAnchorConfig, :t},
      billing_mode: {Dhc.Stripe.SubscriptionsResourceBillingMode, :t},
      billing_schedules: [{Dhc.Stripe.SubscriptionsResourceBillingSchedules, :t}],
      billing_thresholds: {Dhc.Stripe.SubscriptionBillingThresholds, :t},
      cancel_at: {:integer, "unix-time"},
      cancel_at_period_end: :boolean,
      canceled_at: {:integer, "unix-time"},
      cancellation_details: {Dhc.Stripe.CancellationDetails, :t},
      collection_method: {:enum, ["charge_automatically", "send_invoice"]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      days_until_due: :integer,
      default_payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      default_source:
        {:union,
         [:string, {Dhc.Stripe.BankAccount, :t}, {Dhc.Stripe.Card, :t}, {Dhc.Stripe.Source, :t}]},
      default_tax_rates: [{Dhc.Stripe.TaxRate, :t}],
      description: :string,
      discounts: [union: [:string, {Dhc.Stripe.Discount, :t}]],
      ended_at: {:integer, "unix-time"},
      id: :string,
      invoice_settings: {Dhc.Stripe.SubscriptionsResourceSubscriptionInvoiceSettings, :t},
      items: {Dhc.Stripe.SubscriptionItemList, :t},
      latest_invoice: {:union, [:string, {Dhc.Stripe.Invoice, :t}]},
      livemode: :boolean,
      managed_payments: {Dhc.Stripe.SmorResourceManagedPayments, :t},
      metadata: :map,
      next_pending_invoice_item_invoice: {:integer, "unix-time"},
      object: {:const, "subscription"},
      on_behalf_of: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      pause_collection: {Dhc.Stripe.SubscriptionsResourcePauseCollection, :t},
      payment_settings: {Dhc.Stripe.SubscriptionsResourcePaymentSettings, :t},
      pending_invoice_item_interval: {Dhc.Stripe.SubscriptionPendingInvoiceItemInterval, :t},
      pending_setup_intent: {:union, [:string, {Dhc.Stripe.SetupIntent, :t}]},
      pending_update: {Dhc.Stripe.SubscriptionsResourcePendingUpdate, :t},
      presentment_details: {Dhc.Stripe.SubscriptionsResourceSubscriptionPresentmentDetails, :t},
      schedule: {:union, [:string, {Dhc.Stripe.SubscriptionSchedule, :t}]},
      start_date: {:integer, "unix-time"},
      status:
        {:enum,
         [
           "active",
           "canceled",
           "incomplete",
           "incomplete_expired",
           "past_due",
           "paused",
           "trialing",
           "unpaid"
         ]},
      test_clock: {:union, [:string, {Dhc.Stripe.TestHelpersTestClock, :t}]},
      transfer_data: {Dhc.Stripe.SubscriptionTransferData, :t},
      trial_end: {:integer, "unix-time"},
      trial_settings: {Dhc.Stripe.SubscriptionsResourceTrialSettingsTrialSettings, :t},
      trial_start: {:integer, "unix-time"}
    ]
  end
end
