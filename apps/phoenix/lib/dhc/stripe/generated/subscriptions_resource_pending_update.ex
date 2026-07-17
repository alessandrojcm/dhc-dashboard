defmodule Dhc.Stripe.SubscriptionsResourcePendingUpdate do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourcePendingUpdate
  """

  @type t :: %__MODULE__{
          billing_cycle_anchor: integer | nil,
          discount: Dhc.Stripe.Discount.t() | nil,
          discounts: [Dhc.Stripe.Discount.t() | String.t()] | nil,
          expires_at: integer,
          metadata: map | nil,
          subscription_items: [Dhc.Stripe.SubscriptionItem.t()] | nil,
          trial_end: integer | nil,
          trial_from_plan: boolean | nil
        }

  defstruct [
    :billing_cycle_anchor,
    :discount,
    :discounts,
    :expires_at,
    :metadata,
    :subscription_items,
    :trial_end,
    :trial_from_plan
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_cycle_anchor: {:integer, "unix-time"},
      discount: {Dhc.Stripe.Discount, :t},
      discounts: [union: [:string, {Dhc.Stripe.Discount, :t}]],
      expires_at: {:integer, "unix-time"},
      metadata: :map,
      subscription_items: [{Dhc.Stripe.SubscriptionItem, :t}],
      trial_end: {:integer, "unix-time"},
      trial_from_plan: :boolean
    ]
  end
end
