defmodule Dhc.Repo.Migrations.CreateDurableWorkshopPaymentAndRefundWorkflows do
  use Ecto.Migration

  def up do
    create table(:club_activity_payment_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :club_activity_id,
          references(:club_activities, type: :uuid, on_delete: :restrict),
          null: false

      add :member_user_id,
          references(:user_profiles,
            type: :uuid,
            column: :principal_id,
            on_delete: :restrict
          )

      add :external_email, :text
      add :actor_type, :text, null: false
      add :amount, :integer, null: false
      add :currency, :text, null: false, default: "eur"
      add :status, :text, null: false, default: "pending"
      add :stripe_payment_intent_id, :text
      add :stripe_checkout_session_id, :text
      add :paid_at, :timestamptz
      add :concluded_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create unique_index(:club_activity_payment_attempts, [:stripe_payment_intent_id])
    create unique_index(:club_activity_payment_attempts, [:stripe_checkout_session_id])
    create index(:club_activity_payment_attempts, [:club_activity_id])
    create index(:club_activity_payment_attempts, [:status])

    execute """
    CREATE UNIQUE INDEX club_activity_payment_attempts_active_member_unique
      ON club_activity_payment_attempts (club_activity_id, member_user_id)
      WHERE actor_type = 'member' AND status IN ('pending', 'paid')
    """

    execute """
    ALTER TABLE club_activity_payment_attempts
      ADD CONSTRAINT club_activity_payment_attempts_actor_check
      CHECK (
        (actor_type = 'member' AND member_user_id IS NOT NULL AND external_email IS NULL)
        OR (actor_type = 'external' AND member_user_id IS NULL)
      ),
      ADD CONSTRAINT club_activity_payment_attempts_amount_positive
      CHECK (amount > 0),
      ADD CONSTRAINT club_activity_payment_attempts_status_check
      CHECK (status IN ('pending', 'paid', 'registered', 'compensating', 'refunded', 'policy_failed')),
      ADD CONSTRAINT club_activity_payment_attempts_stripe_identifier_xor
      CHECK (num_nonnulls(stripe_payment_intent_id, stripe_checkout_session_id) <= 1)
    """

    alter table(:club_activity_registrations) do
      add :payment_attempt_id,
          references(:club_activity_payment_attempts, type: :uuid, on_delete: :restrict)
    end

    create unique_index(:club_activity_registrations, [:payment_attempt_id])

    alter table(:club_activity_refunds) do
      modify :registration_id, :uuid, null: true

      add :payment_attempt_id,
          references(:club_activity_payment_attempts, type: :uuid, on_delete: :restrict)

      add :idempotency_key, :text
      add :provider_status, :text
      add :last_error, :text
    end

    execute "UPDATE club_activity_refunds SET idempotency_key = 'workshop-refund:' || id::text"
    execute "ALTER TABLE club_activity_refunds ALTER COLUMN idempotency_key SET NOT NULL"

    create unique_index(:club_activity_refunds, [:payment_attempt_id])
    create unique_index(:club_activity_refunds, [:idempotency_key])

    execute """
    ALTER TABLE club_activity_refunds
      ADD CONSTRAINT club_activity_refunds_source_xor
      CHECK (num_nonnulls(registration_id, payment_attempt_id) = 1)
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM club_activity_refunds
        WHERE registration_id IS NULL
      ) THEN
        RAISE EXCEPTION 'ADR 0012 rollback is unsafe after compensating Refund writes; reconcile or restore from backup';
      END IF;
    END
    $$
    """

    execute "ALTER TABLE club_activity_refunds DROP CONSTRAINT club_activity_refunds_source_xor"
    drop index(:club_activity_refunds, [:idempotency_key])
    drop index(:club_activity_refunds, [:payment_attempt_id])

    alter table(:club_activity_refunds) do
      remove :last_error
      remove :provider_status
      remove :idempotency_key
      remove :payment_attempt_id
      modify :registration_id, :uuid, null: false
    end

    drop index(:club_activity_registrations, [:payment_attempt_id])

    alter table(:club_activity_registrations) do
      remove :payment_attempt_id
    end

    drop table(:club_activity_payment_attempts)
  end
end
