defmodule Dhc.Repo.Migrations.FreezeBeginnersIntakeCheckoutParams do
  @moduledoc """
  ALE-381 fix: a Seat Hold freezes the Checkout Session parameters that are
  not already on the payment row, so every create of its session — the
  first and any replay under the same idempotency key — sends exactly the
  same request. Rebuilding them from the Intake and the person at replay
  time made Stripe refuse a replay after a link rotation, an email edit or a
  reschedule, and the hold was then freed while the original session stayed
  payable.

  Additive and nullable (rows from before have no frozen parameters and are
  never replayed by new code paths that require them):

    * `checkout_link_generation` — the Intake link generation whose token
      the session's `success_url` and `cancel_url` carry. The token itself is
      never stored (only its hash, on the Intake): it is rebuilt from the
      Intake id and this generation;
    * `checkout_email` — the prefilled `customer_email`. It is cleared once
      the session is recorded or the hold is released, so no copy of the
      address outlives the hold;
    * `checkout_product_name` — the line item's name (it names the workshop
      date, which a reschedule may change).

  The amount, currency and expiry were already frozen on the row.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intake_payments) do
      add :checkout_link_generation, :integer
      add :checkout_email, :text
      add :checkout_product_name, :text
    end
  end
end
