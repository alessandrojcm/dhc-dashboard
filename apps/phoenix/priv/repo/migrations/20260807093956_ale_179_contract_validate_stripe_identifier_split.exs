defmodule Dhc.Repo.Migrations.Ale179ContractValidateStripeIdentifierSplit do
  @moduledoc """
  ALE-179 (contract): replace the legacy conflated Stripe column and validate
  the split identifier invariant after the code release.

  The expand migration moved `pi_*` values to `stripe_payment_intent_id` and
  left only `cs_*` values in the existing `stripe_checkout_session_id` column.
  This migration replaces that physical legacy column with a fresh canonical
  column of the same application-facing name, preserving all `cs_*` values,
  then rebuilds and validates the CHECK and partial unique against it.

  ALE-179 is unsafe to roll back after writes because its expand backfill moved
  identifiers between columns. Backup-restore is the only supported rollback.
  """

  use Ecto.Migration

  @check :club_activity_registrations_stripe_identifier_xor
  @cs_unique :club_activity_registrations_stripe_checkout_session_id_unique

  def up do
    rename table(:club_activity_registrations),
           :stripe_checkout_session_id,
           to: :stripe_checkout_session_id_legacy

    alter table(:club_activity_registrations) do
      add :stripe_checkout_session_id, :text
    end

    execute """
    UPDATE club_activity_registrations
       SET stripe_checkout_session_id = stripe_checkout_session_id_legacy
    """

    execute """
    ALTER TABLE club_activity_registrations
      DROP CONSTRAINT #{@check}
    """

    drop index(:club_activity_registrations, [:stripe_checkout_session_id_legacy],
           name: @cs_unique
         )

    execute """
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1) NOT VALID
    """

    execute """
    ALTER TABLE club_activity_registrations
      VALIDATE CONSTRAINT #{@check}
    """

    create unique_index(:club_activity_registrations, [:stripe_checkout_session_id],
             name: @cs_unique,
             where: "stripe_checkout_session_id IS NOT NULL"
           )

    alter table(:club_activity_registrations) do
      remove :stripe_checkout_session_id_legacy
    end
  end

  def down do
    raise """
    ALE-179 contract down/0 is unsafe-after-write and not implemented.
    Backup-restore is the only rollback. See ALE-187 runbook.
    """
  end
end
