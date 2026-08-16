defmodule Dhc.Repo.Migrations.ValidateStripeIdentifierSplit do
  @moduledoc """
  ALE-179 (contract): remove legacy PaymentIntent duplicates from the
  Checkout Session column and validate the split identifier invariant after
  the code release.

  The expand migration copied `pi_*` values to `stripe_payment_intent_id` but
  retained the legacy value so the previous application release remained
  compatible. This migration clears only those duplicated `pi_*` values. The
  existing Checkout Session column and partial unique index remain in place,
  avoiding a full-table rewrite and index rebuild.

  ALE-179 is unsafe to roll back after writes because its expand backfill moved
  identifiers between columns. Backup-restore is the only supported rollback.
  """

  use Ecto.Migration

  @check :club_activity_registrations_stripe_identifier_xor

  def up do
    execute """
    DO $$
    DECLARE invalid_identifiers bigint;
    BEGIN
      SELECT count(*) INTO invalid_identifiers
        FROM club_activity_registrations
       WHERE stripe_checkout_session_id IS NOT NULL
         AND (
           left(stripe_checkout_session_id, 3) NOT IN ('pi_', 'cs_')
           OR (
             stripe_payment_intent_id IS NOT NULL
             AND stripe_payment_intent_id IS DISTINCT FROM stripe_checkout_session_id
           )
         );

      IF invalid_identifiers > 0 THEN
        RAISE EXCEPTION
          'Stripe identifier validation: % invalid or conflicting identifiers remain; reconcile them before retrying',
          invalid_identifiers
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    UPDATE club_activity_registrations
       SET stripe_checkout_session_id = NULL
     WHERE left(stripe_checkout_session_id, 3) = 'pi_'
       AND stripe_payment_intent_id = stripe_checkout_session_id
    """

    execute "ALTER TABLE club_activity_registrations DROP CONSTRAINT #{@check}"

    execute """
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1) NOT VALID
    """

    execute """
    ALTER TABLE club_activity_registrations
      VALIDATE CONSTRAINT #{@check}
    """
  end

  def down do
    raise """
    Stripe identifier validation down/0 is unsafe-after-write and not implemented.
    Backup-restore is the only rollback.
    """
  end
end
