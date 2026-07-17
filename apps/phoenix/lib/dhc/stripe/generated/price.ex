defmodule Dhc.Stripe.Price do
  @moduledoc """
  Provides struct and type for a Price
  """

  @type t :: %__MODULE__{
          active: boolean,
          billing_scheme: String.t(),
          created: integer,
          currency: String.t(),
          currency_options: map | nil,
          custom_unit_amount: Dhc.Stripe.CustomUnitAmount.t() | nil,
          id: String.t(),
          livemode: boolean,
          lookup_key: String.t() | nil,
          metadata: map,
          nickname: String.t() | nil,
          object: String.t(),
          product: Dhc.Stripe.DeletedProduct.t() | Dhc.Stripe.Product.t() | String.t(),
          recurring: Dhc.Stripe.Recurring.t() | nil,
          tax_behavior: String.t() | nil,
          tiers: [Dhc.Stripe.PriceTier.t()] | nil,
          tiers_mode: String.t() | nil,
          transform_quantity: Dhc.Stripe.TransformQuantity.t() | nil,
          type: String.t(),
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil
        }

  defstruct [
    :active,
    :billing_scheme,
    :created,
    :currency,
    :currency_options,
    :custom_unit_amount,
    :id,
    :livemode,
    :lookup_key,
    :metadata,
    :nickname,
    :object,
    :product,
    :recurring,
    :tax_behavior,
    :tiers,
    :tiers_mode,
    :transform_quantity,
    :type,
    :unit_amount,
    :unit_amount_decimal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      billing_scheme: {:enum, ["per_unit", "tiered"]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      currency_options: :map,
      custom_unit_amount: {Dhc.Stripe.CustomUnitAmount, :t},
      id: :string,
      livemode: :boolean,
      lookup_key: :string,
      metadata: :map,
      nickname: :string,
      object: {:const, "price"},
      product: {:union, [:string, {Dhc.Stripe.DeletedProduct, :t}, {Dhc.Stripe.Product, :t}]},
      recurring: {Dhc.Stripe.Recurring, :t},
      tax_behavior: {:enum, ["exclusive", "inclusive", "unspecified"]},
      tiers: [{Dhc.Stripe.PriceTier, :t}],
      tiers_mode: {:enum, ["graduated", "volume"]},
      transform_quantity: {Dhc.Stripe.TransformQuantity, :t},
      type: {:enum, ["one_time", "recurring"]},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
