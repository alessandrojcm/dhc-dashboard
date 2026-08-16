defmodule Dhc.Repo.Migrations.ExpandStripeIdentifierSplit do
  @moduledoc """
  ALE-179 (expand): split the conflated Stripe identifier on
  `club_activity_registrations` into two columns.

  ## Why

  The single `stripe_checkout_session_id` column historically held *both*
  Stripe PaymentIntent ids (`pi_*`, written by the authenticated member
  registration path) and Checkout Session ids (`cs_*`, written by the
  external registration path). That conflation made the refund path
  incorrect for external rows (a `cs_*` id is not a valid `payment_intent`
  argument to `/v1/refunds`) and prevented a precise uniqueness guarantee
  per identifier kind.

  ## What this expand migration does

    1. Adds `stripe_payment_intent_id` (`pi_*`) — a new nullable column.
       The existing `stripe_checkout_session_id` column keeps its name and
       values during the compatibility release.
    2. Backfills `stripe_payment_intent_id` from the existing column by
       prefix: every value starting with `pi_` is copied to the new
       column. A zero-unparseable assertion guards the backfill — any row
       whose old value is non-null but matches neither `pi_` nor `cs_`
       aborts the migration (no payment intent is silently lost).
    3. Adds a transitional CHECK allowing both columns only when they hold
       the same legacy PaymentIntent. The contract migration replaces it
       with the final at-most-one invariant after old code is drained.
    4. Replaces the conflated unique with one partial unique per physical
       column while retaining the compatibility values.

  The old column is preserved untouched in name, type, and value. Existing
  application code keeps working until the ALE-193 code release deploys and
  writes only the new columns.

  ## down/0

  Unsafe-after-write once the code release writes the new column.
  Backup-restore is the only rollback. `down/0` raises to make this explicit
  rather than silently no-op.
  """

  use Ecto.Migration

  @old_unique :club_activity_registrations_stripe_checkout_session_id_index
  @pi_unique :club_activity_registrations_stripe_payment_intent_id_unique
  @cs_unique :club_activity_registrations_stripe_checkout_session_id_unique
  @check :club_activity_registrations_stripe_identifier_xor

  def up do
    # 1. Add the new PaymentIntent column. The existing conflated column stays
    #    intact during the expand release so the previous application version
    #    can continue reading both `pi_*` and `cs_*` identifiers.
    alter table(:club_activity_registrations) do
      add :stripe_payment_intent_id, :text
    end

    # 2. Copy PaymentIntent identifiers to the new column without clearing the
    #    legacy value. `left/2` matches the underscore literally; SQL LIKE
    #    would treat it as a single-character wildcard.
    execute """
    UPDATE club_activity_registrations
       SET stripe_payment_intent_id = stripe_checkout_session_id
     WHERE stripe_checkout_session_id IS NOT NULL
       AND left(stripe_checkout_session_id, 3) = 'pi_'
    """

    # Zero-unparseable data gate: the legacy column may contain either kind
    # during compatibility, but no other prefix.
    execute """
    DO $$
    DECLARE unparseable int;
    BEGIN
      SELECT count(*) INTO unparseable
        FROM club_activity_registrations
       WHERE stripe_checkout_session_id IS NOT NULL
         AND left(stripe_checkout_session_id, 3) NOT IN ('pi_', 'cs_');

      IF unparseable > 0 THEN
        RAISE EXCEPTION
          'Stripe identifier expansion: % unparseable identifiers remain in stripe_checkout_session_id (expected pi_* or cs_*)',
          unparseable
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # 3. Transitional CHECK. Existing `pi_*` rows intentionally carry the
    #    same value in both columns until contract; genuinely conflicting
    #    identifiers are rejected. New code writes only one canonical column.
    execute """
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (
        stripe_payment_intent_id IS NULL
        OR stripe_checkout_session_id IS NULL
        OR stripe_payment_intent_id = stripe_checkout_session_id
      ) NOT VALID
    """

    # 4. Replace the conflated unique with one partial unique per column.
    drop_if_exists(
      unique_index(:club_activity_registrations, [:stripe_checkout_session_id], name: @old_unique)
    )

    create(
      unique_index(:club_activity_registrations, [:stripe_payment_intent_id],
        name: @pi_unique,
        where: "stripe_payment_intent_id IS NOT NULL"
      )
    )

    create(
      unique_index(:club_activity_registrations, [:stripe_checkout_session_id],
        name: @cs_unique,
        where: "stripe_checkout_session_id IS NOT NULL"
      )
    )
  end

  def down do
    # Unsafe-after-write. The backfill and the `pi_*` clear are one-way: a
    # rollback cannot reconstruct which `pi_*` value lived in the old
    # column for a row that has since been written with a `cs_*` id by the
    # code release. Backup-restore is the only rollback. Raise rather than
    # silently no-op so an operator does not mistake a no-op for a real
    # rollback.
    raise """
    Stripe identifier expansion down/0 is unsafe-after-write and not implemented.
    The backfill and the pi_* clear are one-way. Backup-restore is the
    only rollback.
    """
  end
end
