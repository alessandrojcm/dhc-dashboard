defmodule Dhc.Stripe.SubscriptionDataParams do
  @moduledoc """
  Provides struct and type for a SubscriptionDataParams
  """

  @type t :: %__MODULE__{
          application_fee_percent: number | nil,
          billing_cycle_anchor: integer | nil,
          billing_cycle_anchor_config: Dhc.Stripe.CycleAnchorConfigParam.t() | nil,
          billing_mode: Dhc.Stripe.BillingMode.t() | nil,
          default_tax_rates: [String.t()] | nil,
          description: String.t() | nil,
          invoice_settings: Dhc.Stripe.InvoiceSettingsParams.t() | nil,
          metadata: map | nil,
          on_behalf_of: String.t() | nil,
          pending_invoice_item_interval: Dhc.Stripe.PendingInvoiceItemIntervalParams.t() | nil,
          proration_behavior: String.t() | nil,
          transfer_data: Dhc.Stripe.TransferDataSpecs.t() | nil,
          trial_end: integer | nil,
          trial_period_days: integer | nil,
          trial_settings: Dhc.Stripe.TrialSettingsConfig.t() | nil
        }

  defstruct [
    :application_fee_percent,
    :billing_cycle_anchor,
    :billing_cycle_anchor_config,
    :billing_mode,
    :default_tax_rates,
    :description,
    :invoice_settings,
    :metadata,
    :on_behalf_of,
    :pending_invoice_item_interval,
    :proration_behavior,
    :transfer_data,
    :trial_end,
    :trial_period_days,
    :trial_settings
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application_fee_percent: :number,
      billing_cycle_anchor: {:integer, "unix-time"},
      billing_cycle_anchor_config: {Dhc.Stripe.CycleAnchorConfigParam, :t},
      billing_mode: {Dhc.Stripe.BillingMode, :t},
      default_tax_rates: [:string],
      description: :string,
      invoice_settings: {Dhc.Stripe.InvoiceSettingsParams, :t},
      metadata: :map,
      on_behalf_of: :string,
      pending_invoice_item_interval: {Dhc.Stripe.PendingInvoiceItemIntervalParams, :t},
      proration_behavior: {:enum, ["create_prorations", "none"]},
      transfer_data: {Dhc.Stripe.TransferDataSpecs, :t},
      trial_end: {:integer, "unix-time"},
      trial_period_days: :integer,
      trial_settings: {Dhc.Stripe.TrialSettingsConfig, :t}
    ]
  end
end
