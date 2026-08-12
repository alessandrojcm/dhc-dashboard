defmodule Dhc.Stripe.SubscriptionDetailsParams do
  @moduledoc """
  Provides struct and type for a SubscriptionDetailsParams
  """

  @type t :: %__MODULE__{
          billing_cycle_anchor: integer | String.t() | nil,
          billing_mode: Dhc.Stripe.BillingMode.t() | nil,
          billing_schedules: String.t() | [map] | nil,
          cancel_at: integer | String.t() | nil,
          cancel_at_period_end: boolean | nil,
          cancel_now: boolean | nil,
          default_tax_rates: String.t() | [String.t()] | nil,
          items: [Dhc.Stripe.SubscriptionItemUpdateParams.t()] | nil,
          metadata: map | String.t() | nil,
          proration_behavior: String.t() | nil,
          proration_date: integer | nil,
          resume_at: String.t() | nil,
          start_date: integer | nil,
          trial_end: integer | String.t() | nil
        }

  defstruct [
    :billing_cycle_anchor,
    :billing_mode,
    :billing_schedules,
    :cancel_at,
    :cancel_at_period_end,
    :cancel_now,
    :default_tax_rates,
    :items,
    :metadata,
    :proration_behavior,
    :proration_date,
    :resume_at,
    :start_date,
    :trial_end
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_cycle_anchor: {:union, enum: ["now", "unchanged"], integer: "unix-time"},
      billing_mode: {Dhc.Stripe.BillingMode, :t},
      billing_schedules: {:union, [{:const, ""}, [:map]]},
      cancel_at:
        {:union,
         const: "",
         enum: ["max_billed_until", "max_period_end", "min_period_end"],
         integer: "unix-time"},
      cancel_at_period_end: :boolean,
      cancel_now: :boolean,
      default_tax_rates: {:union, [{:const, ""}, [:string]]},
      items: [{Dhc.Stripe.SubscriptionItemUpdateParams, :t}],
      metadata: {:union, [:map, const: ""]},
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]},
      proration_date: {:integer, "unix-time"},
      resume_at: {:const, "now"},
      start_date: {:integer, "unix-time"},
      trial_end: {:union, const: "now", integer: "unix-time"}
    ]
  end
end
