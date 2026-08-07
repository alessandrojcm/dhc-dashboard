defmodule Dhc.Workshops.Ale179ContractStripeIdentifierSplitTest do
  use Dhc.DataCase, async: false

  alias Dhc.Repo

  @check "club_activity_registrations_stripe_identifier_xor"

  test "the split identifier constraint is validated" do
    assert [[true, definition]] =
             Repo.query!(
               "SELECT convalidated, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
               [@check]
             ).rows

    assert definition =~ "num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1"
  end

  test "the canonical Checkout Session column remains available" do
    assert [[true]] =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'club_activity_registrations' AND column_name = 'stripe_checkout_session_id')"
             ).rows
  end

  test "the physical legacy Checkout Session column is gone" do
    assert [[false]] =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'club_activity_registrations' AND column_name = 'stripe_checkout_session_id_legacy')"
             ).rows
  end
end
