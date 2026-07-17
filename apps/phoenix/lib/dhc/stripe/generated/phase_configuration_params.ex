defmodule Dhc.Stripe.PhaseConfigurationParams do
  @moduledoc """
  Provides struct and type for a PhaseConfigurationParams
  """

  @type t :: %__MODULE__{
          add_invoice_items: [Dhc.Stripe.AddInvoiceItemEntry.t()] | nil,
          application_fee_percent: number | nil,
          automatic_tax: Dhc.Stripe.AutomaticTaxConfig.t() | nil,
          billing_cycle_anchor: String.t() | nil,
          billing_thresholds: Dhc.Stripe.BillingThresholdsParam.t() | String.t() | nil,
          collection_method: String.t() | nil,
          default_payment_method: String.t() | nil,
          default_tax_rates: String.t() | [String.t()] | nil,
          description: String.t() | nil,
          discounts: String.t() | [map] | nil,
          duration: Dhc.Stripe.DurationParams.t() | nil,
          end_date: integer | String.t() | nil,
          invoice_settings: Dhc.Stripe.InvoiceSettings.t() | nil,
          items: [Dhc.Stripe.ConfigurationItemParams.t()],
          metadata: map | nil,
          on_behalf_of: String.t() | nil,
          proration_behavior: String.t() | nil,
          start_date: integer | String.t() | nil,
          transfer_data: Dhc.Stripe.TransferDataSpecs.t() | nil,
          trial: boolean | nil,
          trial_end: integer | String.t() | nil
        }

  defstruct [
    :add_invoice_items,
    :application_fee_percent,
    :automatic_tax,
    :billing_cycle_anchor,
    :billing_thresholds,
    :collection_method,
    :default_payment_method,
    :default_tax_rates,
    :description,
    :discounts,
    :duration,
    :end_date,
    :invoice_settings,
    :items,
    :metadata,
    :on_behalf_of,
    :proration_behavior,
    :start_date,
    :transfer_data,
    :trial,
    :trial_end
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      add_invoice_items: [{Dhc.Stripe.AddInvoiceItemEntry, :t}],
      application_fee_percent: :number,
      automatic_tax: {Dhc.Stripe.AutomaticTaxConfig, :t},
      billing_cycle_anchor: {:enum, ["automatic", "phase_start"]},
      billing_thresholds: {:union, [{Dhc.Stripe.BillingThresholdsParam, :t}, const: ""]},
      collection_method: {:enum, ["charge_automatically", "send_invoice"]},
      default_payment_method: :string,
      default_tax_rates: {:union, [{:const, ""}, [:string]]},
      description: {:union, [:string, const: ""]},
      discounts: {:union, [{:const, ""}, [:map]]},
      duration: {Dhc.Stripe.DurationParams, :t},
      end_date: {:union, const: "now", integer: "unix-time"},
      invoice_settings: {Dhc.Stripe.InvoiceSettings, :t},
      items: [{Dhc.Stripe.ConfigurationItemParams, :t}],
      metadata: :map,
      on_behalf_of: :string,
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]},
      start_date: {:union, const: "now", integer: "unix-time"},
      transfer_data: {Dhc.Stripe.TransferDataSpecs, :t},
      trial: :boolean,
      trial_end: {:union, const: "now", integer: "unix-time"}
    ]
  end
end
