defmodule Dhc.Stripe.SubscriptionScheduleConfigurationItem do
  @moduledoc """
  Provides struct and type for a SubscriptionScheduleConfigurationItem
  """

  @type t :: %__MODULE__{
          billing_thresholds: Dhc.Stripe.SubscriptionItemBillingThresholds.t() | nil,
          discounts: [Dhc.Stripe.StackableDiscountWithDiscountSettings.t()],
          metadata: map | nil,
          price: Dhc.Stripe.DeletedPrice.t() | Dhc.Stripe.Price.t() | String.t(),
          quantity: integer | nil,
          tax_rates: [Dhc.Stripe.TaxRate.t()] | nil
        }

  defstruct [:billing_thresholds, :discounts, :metadata, :price, :quantity, :tax_rates]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_thresholds: {Dhc.Stripe.SubscriptionItemBillingThresholds, :t},
      discounts: [{Dhc.Stripe.StackableDiscountWithDiscountSettings, :t}],
      metadata: :map,
      price: {:union, [:string, {Dhc.Stripe.DeletedPrice, :t}, {Dhc.Stripe.Price, :t}]},
      quantity: :integer,
      tax_rates: [{Dhc.Stripe.TaxRate, :t}]
    ]
  end
end
