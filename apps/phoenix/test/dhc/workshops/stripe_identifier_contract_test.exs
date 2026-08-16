defmodule Dhc.Workshops.StripeIdentifierContractTest do
  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures

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

  test "contract clears only the duplicated legacy PaymentIntent value" do
    workshop = WorkshopFixtures.workshop_fixture()
    %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()
    payment_intent_id = "pi_contract_#{System.unique_integer([:positive])}"

    Repo.query!("ALTER TABLE club_activity_registrations DROP CONSTRAINT #{@check}")

    Repo.query!(
      """
      INSERT INTO club_activity_registrations
        (id, club_activity_id, member_user_id, display_name,
         stripe_payment_intent_id, stripe_checkout_session_id,
         amount_paid, currency, status, registered_at, created_at, updated_at)
      VALUES ($1, $2, $3, 'Member Test', $4, $4, 1000, 'eur', 'confirmed', NOW(), NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(workshop.id),
        Ecto.UUID.dump!(user_id),
        payment_intent_id
      ]
    )

    Repo.query!("""
    UPDATE club_activity_registrations
       SET stripe_checkout_session_id = NULL
     WHERE left(stripe_checkout_session_id, 3) = 'pi_'
       AND stripe_payment_intent_id = stripe_checkout_session_id
    """)

    Repo.query!("""
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1)
    """)

    assert [[^payment_intent_id, nil]] =
             Repo.query!(
               "SELECT stripe_payment_intent_id, stripe_checkout_session_id FROM club_activity_registrations WHERE member_user_id = $1",
               [Ecto.UUID.dump!(user_id)]
             ).rows
  end
end
