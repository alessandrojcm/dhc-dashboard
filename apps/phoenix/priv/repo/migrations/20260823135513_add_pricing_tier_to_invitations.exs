defmodule Dhc.Repo.Migrations.AddPricingTierToInvitations do
  use Ecto.Migration

  @moduledoc """
  Adds `invitations.pricing_tier` so the admin indicates the membership
  discount at issue time (ADR-0010 carrier pattern: the invitation row
  carries invite intent between issue and acceptance).

  Tiers map to private Stripe coupon IDs resolved at acceptance:

  - `standard` — no discount (default).
  - `student` — coupon with 20% off, scoped to the monthly
    product; the annual subscription is created without the discount.
  - `coach` — coupon with 100% percent off, duration forever, applying to
    both products, so every invoice on both subscriptions is zero.

  Coupon shapes live in the Stripe dashboard; IDs are wired through the
  `:dhc, :membership_tier_coupons` application config.
  """

  def change do
    alter table(:invitations, primary_key: false) do
      add :pricing_tier, :text, null: false, default: "standard"
    end
  end
end
