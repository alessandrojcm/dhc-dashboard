defmodule Dhc.Stripe.PortalSubscriptionUpdate do
  @moduledoc """
  Provides struct and type for a PortalSubscriptionUpdate
  """

  @type t :: %__MODULE__{
          billing_cycle_anchor: String.t() | nil,
          default_allowed_updates: [String.t()],
          enabled: boolean,
          products: [Dhc.Stripe.PortalSubscriptionUpdateProduct.t()] | nil,
          proration_behavior: String.t(),
          schedule_at_period_end: Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEnd.t(),
          trial_update_behavior: String.t()
        }

  defstruct [
    :billing_cycle_anchor,
    :default_allowed_updates,
    :enabled,
    :products,
    :proration_behavior,
    :schedule_at_period_end,
    :trial_update_behavior
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_cycle_anchor: {:enum, ["now", "unchanged"]},
      default_allowed_updates: [enum: ["price", "promotion_code", "quantity"]],
      enabled: :boolean,
      products: [{Dhc.Stripe.PortalSubscriptionUpdateProduct, :t}],
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]},
      schedule_at_period_end: {Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEnd, :t},
      trial_update_behavior: {:enum, ["continue_trial", "end_trial"]}
    ]
  end
end
