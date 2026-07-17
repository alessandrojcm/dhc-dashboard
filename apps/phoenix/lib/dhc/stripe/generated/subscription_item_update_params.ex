defmodule Dhc.Stripe.SubscriptionItemUpdateParams do
  @moduledoc """
  Provides struct and types for a SubscriptionItemUpdateParams
  """

  @type t :: %__MODULE__{
          billing_thresholds: Dhc.Stripe.ItemBillingThresholdsParam.t() | String.t() | nil,
          clear_usage: boolean | nil,
          deleted: boolean | nil,
          discounts: String.t() | [map] | nil,
          id: String.t() | nil,
          metadata: map | String.t() | nil,
          price: String.t() | nil,
          price_data: Dhc.Stripe.RecurringPriceData.t() | nil,
          quantity: integer | nil,
          tax_rates: String.t() | [String.t()] | nil
        }

  defstruct [
    :billing_thresholds,
    :clear_usage,
    :deleted,
    :discounts,
    :id,
    :metadata,
    :price,
    :price_data,
    :quantity,
    :tax_rates
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_thresholds: {:union, [{Dhc.Stripe.ItemBillingThresholdsParam, :t}, const: ""]},
      clear_usage: :boolean,
      deleted: :boolean,
      discounts: {:union, [{:const, ""}, [:map]]},
      id: :string,
      metadata: {:union, [:map, const: ""]},
      price: :string,
      price_data: {Dhc.Stripe.RecurringPriceData, :t},
      quantity: :integer,
      tax_rates: {:union, [{:const, ""}, [:string]]}
    ]
  end
end
