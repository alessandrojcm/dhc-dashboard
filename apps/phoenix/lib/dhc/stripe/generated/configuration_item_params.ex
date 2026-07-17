defmodule Dhc.Stripe.ConfigurationItemParams do
  @moduledoc """
  Provides struct and type for a ConfigurationItemParams
  """

  @type t :: %__MODULE__{
          billing_thresholds: Dhc.Stripe.ItemBillingThresholdsParam.t() | String.t() | nil,
          discounts: String.t() | [map] | nil,
          metadata: map | nil,
          price: String.t() | nil,
          price_data: Dhc.Stripe.RecurringPriceData.t() | nil,
          quantity: integer | nil,
          tax_rates: String.t() | [String.t()] | nil
        }

  defstruct [
    :billing_thresholds,
    :discounts,
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
      discounts: {:union, [{:const, ""}, [:map]]},
      metadata: :map,
      price: :string,
      price_data: {Dhc.Stripe.RecurringPriceData, :t},
      quantity: :integer,
      tax_rates: {:union, [{:const, ""}, [:string]]}
    ]
  end
end
