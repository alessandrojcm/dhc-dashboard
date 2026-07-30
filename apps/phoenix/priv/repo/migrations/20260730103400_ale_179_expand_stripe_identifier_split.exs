defmodule Dhc.Repo.Migrations.Ale179ExpandStripeIdentifierSplit do
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
       ends up holding only `cs_*` ids (the `pi_*` values are moved out of
       it in step 3).
    2. Backfills `stripe_payment_intent_id` from the existing column by
       prefix: every value starting with `pi_` is copied to the new
       column. A zero-unparseable assertion guards the backfill — any row
       whose old value is non-null but matches neither `pi_` nor `cs_`
       aborts the migration (no payment intent is silently lost).
    3. Clears the `pi_*` values out of the old `stripe_checkout_session_id`
       column so it holds only `cs_*` after expand. The old column is kept
       (the contract migration, ALE-194, drops it once the code release
       stops writing to it).
    4. Adds `CHECK (num_nonnulls(stripe_payment_intent_id,
       stripe_checkout_session_id) <= 1) NOT VALID`. The invariant is "at
       most one identifier kind per row" — never both. It is `<= 1` rather
       than `= 1` because a registration may legitimately have no Stripe
       identifier (free registrations, the no-pay refund branch, and the
       test fixtures that bypass Stripe). `NOT VALID` skips existing rows
       (already correct after backfill); the contract migration validates
       it once the code release writes only the new columns.
     5. Drops the old `club_activity_registrations_stripe_checkout_session_id_index`
        unique (it spanned the conflated column) and adds two new partial
        uniques, one per split column, each `WHERE col IS NOT NULL`.

  The old column is preserved untouched in name and type; only its `pi_*`
  values are cleared. Existing application code (which reads/writes
  `stripe_checkout_session_id`) keeps working until the ALE-193 code
  release deploys and writes only the new columns.

  ## down/0

  Unsafe-after-write. The backfill and the `pi_*` clear are one-way: a
  rollback cannot reconstruct which `pi_*` value lived in the old column
  for a row that has since been written with a `cs_*` id by the code
  release. Backup-restore is the only rollback. `down/0` raises to make
  this explicit rather than silently no-op.
  """

  use Ecto.Migration

  @old_unique :club_activity_registrations_stripe_checkout_session_id_index
  @pi_unique :club_activity_registrations_stripe_payment_intent_id_unique
  @cs_unique :club_activity_registrations_stripe_checkout_session_id_unique
  @check :club_activity_registrations_stripe_identifier_xor

  def up do
    # 1. Add the new PaymentIntent column. The existing
    #    `stripe_checkout_session_id` column keeps its name and will hold
    #    only `cs_*` after the clear in step 3.
    alter table(:club_activity_registrations) do
      add :stripe_payment_intent_id, :text
    end

    # 2. Backfill the new column from the old column by prefix, and assert
    #    zero unparseable rows. A row whose old value is non-null but
    #    matches neither `pi_` nor `cs_` aborts the migration — no payment
    #    intent is silently lost.
    execute """
    UPDATE club_activity_registrations
       SET stripe_payment_intent_id = stripe_checkout_session_id
     WHERE stripe_checkout_session_id IS NOT NULL
       AND stripe_checkout_session_id LIKE 'pi_%'
    """

    execute """
    UPDATE club_activity_registrations
       SET stripe_checkout_session_id = NULL
     WHERE stripe_checkout_session_id LIKE 'pi_%'
    """

    # Zero-unparseable data gate: any non-null old value that was neither
    # a `pi_*` nor a `cs_*` must abort the window. By this point `pi_*`
    # values have been moved out and cleared, so a remaining non-null,
    # non-`cs_*` value is unparseable.
    execute """
    DO $$
    DECLARE unparseable int;
    BEGIN
      SELECT count(*) INTO unparseable
        FROM club_activity_registrations
       WHERE stripe_checkout_session_id IS NOT NULL
         AND stripe_checkout_session_id NOT LIKE 'cs_%';

      IF unparseable > 0 THEN
        RAISE EXCEPTION
          'ALE-179 expand: % unparseable Stripe identifiers remain in stripe_checkout_session_id (expected only cs_* after backfill)',
          unparseable
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    # 3. CHECK (at most one identifier kind). `<= 1` rather than `= 1`
    #    because a registration may have no Stripe id (free registrations,
    #    the no-pay refund branch, test fixtures that bypass Stripe).
    #    `NOT VALID` skips existing rows; the contract migration validates
    #    it once the code release writes only the new columns.
    execute """
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1) NOT VALID
    """

    # 4. Swap the unique: drop the old conflated unique, add two partial
    #    uniques — one per split column.
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
    ALE-179 expand down/0 is unsafe-after-write and not implemented.
    The backfill and the pi_* clear are one-way. Backup-restore is the
    only rollback. See ALE-187 runbook.
    """
  end
end
