defmodule Dhc.Stripe.PromotionCode do
  @moduledoc """
  Provides struct and type for a PromotionCode
  """

  @type t :: %__MODULE__{
          active: boolean,
          code: String.t(),
          created: integer,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          customer_account: String.t() | nil,
          expires_at: integer | nil,
          id: String.t(),
          livemode: boolean,
          max_redemptions: integer | nil,
          metadata: map | nil,
          object: String.t(),
          promotion: Dhc.Stripe.PromotionCodesResourcePromotion.t(),
          restrictions: Dhc.Stripe.PromotionCodesResourceRestrictions.t(),
          times_redeemed: integer
        }

  defstruct [
    :active,
    :code,
    :created,
    :customer,
    :customer_account,
    :expires_at,
    :id,
    :livemode,
    :max_redemptions,
    :metadata,
    :object,
    :promotion,
    :restrictions,
    :times_redeemed
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      code: :string,
      created: {:integer, "unix-time"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      expires_at: {:integer, "unix-time"},
      id: :string,
      livemode: :boolean,
      max_redemptions: :integer,
      metadata: :map,
      object: {:const, "promotion_code"},
      promotion: {Dhc.Stripe.PromotionCodesResourcePromotion, :t},
      restrictions: {Dhc.Stripe.PromotionCodesResourceRestrictions, :t},
      times_redeemed: :integer
    ]
  end
end
