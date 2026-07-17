defmodule Dhc.Stripe.SubscriptionItem do
  @moduledoc """
  Provides struct and type for a SubscriptionItem
  """

  @type t :: %__MODULE__{
          billed_until: integer | nil,
          billing_thresholds: Dhc.Stripe.SubscriptionItemBillingThresholds.t() | nil,
          created: integer,
          current_period_end: integer,
          current_period_start: integer,
          discounts: [Dhc.Stripe.Discount.t() | String.t()],
          id: String.t(),
          metadata: map,
          object: String.t(),
          price: Dhc.Stripe.Price.t(),
          quantity: integer | nil,
          subscription: String.t(),
          tax_rates: [Dhc.Stripe.TaxRate.t()] | nil
        }

  defstruct [
    :billed_until,
    :billing_thresholds,
    :created,
    :current_period_end,
    :current_period_start,
    :discounts,
    :id,
    :metadata,
    :object,
    :price,
    :quantity,
    :subscription,
    :tax_rates
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billed_until: {:integer, "unix-time"},
      billing_thresholds: {Dhc.Stripe.SubscriptionItemBillingThresholds, :t},
      created: :integer,
      current_period_end: {:integer, "unix-time"},
      current_period_start: {:integer, "unix-time"},
      discounts: [union: [:string, {Dhc.Stripe.Discount, :t}]],
      id: :string,
      metadata: :map,
      object: {:const, "subscription_item"},
      price: {Dhc.Stripe.Price, :t},
      quantity: :integer,
      subscription: :string,
      tax_rates: [{Dhc.Stripe.TaxRate, :t}]
    ]
  end
end
