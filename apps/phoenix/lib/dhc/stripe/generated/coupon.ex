defmodule Dhc.Stripe.Coupon do
  @moduledoc """
  Provides struct and type for a Coupon
  """

  @type t :: %__MODULE__{
          amount_off: integer | nil,
          applies_to: Dhc.Stripe.CouponAppliesTo.t() | nil,
          created: integer,
          currency: String.t() | nil,
          currency_options: map | nil,
          duration: String.t(),
          duration_in_months: integer | nil,
          id: String.t(),
          livemode: boolean,
          max_redemptions: integer | nil,
          metadata: map | nil,
          name: String.t() | nil,
          object: String.t(),
          percent_off: number | nil,
          redeem_by: integer | nil,
          times_redeemed: integer,
          valid: boolean
        }

  defstruct [
    :amount_off,
    :applies_to,
    :created,
    :currency,
    :currency_options,
    :duration,
    :duration_in_months,
    :id,
    :livemode,
    :max_redemptions,
    :metadata,
    :name,
    :object,
    :percent_off,
    :redeem_by,
    :times_redeemed,
    :valid
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_off: :integer,
      applies_to: {Dhc.Stripe.CouponAppliesTo, :t},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      currency_options: :map,
      duration: {:enum, ["forever", "once", "repeating"]},
      duration_in_months: :integer,
      id: :string,
      livemode: :boolean,
      max_redemptions: :integer,
      metadata: :map,
      name: :string,
      object: {:const, "coupon"},
      percent_off: :number,
      redeem_by: {:integer, "unix-time"},
      times_redeemed: :integer,
      valid: :boolean
    ]
  end
end
