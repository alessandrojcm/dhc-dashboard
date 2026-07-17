defmodule Dhc.Stripe.ShippingRate do
  @moduledoc """
  Provides struct and type for a ShippingRate
  """

  @type t :: %__MODULE__{
          active: boolean,
          created: integer,
          delivery_estimate: Dhc.Stripe.ShippingRateDeliveryEstimate.t() | nil,
          display_name: String.t() | nil,
          fixed_amount: Dhc.Stripe.ShippingRateFixedAmount.t() | nil,
          id: String.t(),
          livemode: boolean,
          metadata: map,
          object: String.t(),
          tax_behavior: String.t() | nil,
          tax_code: Dhc.Stripe.TaxCode.t() | String.t() | nil,
          type: String.t()
        }

  defstruct [
    :active,
    :created,
    :delivery_estimate,
    :display_name,
    :fixed_amount,
    :id,
    :livemode,
    :metadata,
    :object,
    :tax_behavior,
    :tax_code,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      created: {:integer, "unix-time"},
      delivery_estimate: {Dhc.Stripe.ShippingRateDeliveryEstimate, :t},
      display_name: :string,
      fixed_amount: {Dhc.Stripe.ShippingRateFixedAmount, :t},
      id: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "shipping_rate"},
      tax_behavior: {:enum, ["exclusive", "inclusive", "unspecified"]},
      tax_code: {:union, [:string, {Dhc.Stripe.TaxCode, :t}]},
      type: {:const, "fixed_amount"}
    ]
  end
end
