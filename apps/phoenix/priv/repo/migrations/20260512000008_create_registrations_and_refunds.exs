defmodule Dhc.Repo.Migrations.CreateRegistrationsAndRefunds do
  use Ecto.Migration

  def up do
    # ── external_users ──────────────────────────────────────
    create table(:external_users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :first_name, :text, null: false
      add :last_name, :text, null: false
      add :email, :text, null: false
      add :phone_number, :text

      timestamps(type: :timestamptz)
    end

    create unique_index(:external_users, [:email])

    # ── club_activity_registrations ─────────────────────────
    create table(:club_activity_registrations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :club_activity_id,
          references(:club_activities, type: :uuid, on_delete: :delete_all),
          null: false

      add :member_user_id,
          references(:user_profiles,
            type: :uuid,
            column: :supabase_user_id,
            on_delete: :delete_all
          )

      add :external_user_id,
          references(:external_users, type: :uuid, on_delete: :delete_all)

      add :stripe_checkout_session_id, :text
      add :amount_paid, :integer, null: false
      add :currency, :text, null: false, default: "eur"
      add :status, :registration_status, null: false, default: "pending"
      add :registered_at, :timestamptz, default: fragment("NOW()")
      add :confirmed_at, :timestamptz
      add :cancelled_at, :timestamptz
      add :registration_notes, :text
      add :attendance_status, :text, default: "pending"
      add :attendance_marked_at, :timestamptz

      add :attendance_marked_by,
          references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)

      add :attendance_notes, :text

      timestamps(type: :timestamptz)
    end

    create unique_index(:club_activity_registrations, [:stripe_checkout_session_id])
    create unique_index(:club_activity_registrations, [:club_activity_id, :member_user_id])
    create unique_index(:club_activity_registrations, [:club_activity_id, :external_user_id])
    create index(:club_activity_registrations, [:club_activity_id])
    create index(:club_activity_registrations, [:member_user_id])
    create index(:club_activity_registrations, [:external_user_id])
    # The unique_index on :stripe_checkout_session_id above already serves
    # lookups; a duplicate non-unique index on the same column collides on the
    # generated index name.
    create index(:club_activity_registrations, [:status])
    create index(:club_activity_registrations, [:attendance_status])
    create index(:club_activity_registrations, [:attendance_marked_at])

    execute """
    ALTER TABLE club_activity_registrations
    ADD CONSTRAINT attendance_status_check
    CHECK (attendance_status IN ('pending', 'attended', 'no_show', 'excused'))
    """

    # ── club_activity_refunds ──────────────────────────────
    create table(:club_activity_refunds, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :registration_id,
          references(:club_activity_registrations, type: :uuid, on_delete: :delete_all),
          null: false

      add :refund_amount, :integer, null: false
      add :refund_reason, :text
      add :status, :refund_status, null: false, default: "pending"
      add :stripe_refund_id, :text
      add :stripe_payment_intent_id, :text
      add :requested_at, :timestamptz, null: false, default: fragment("NOW()")
      add :processed_at, :timestamptz
      add :completed_at, :timestamptz
      add :requested_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)
      add :processed_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)

      timestamps(type: :timestamptz)
    end

    # The unique_indexes on :registration_id and :stripe_refund_id already
    # serve lookups; duplicate non-unique indexes on the same columns collide
    # on the generated index names.
    create unique_index(:club_activity_refunds, [:registration_id])
    create unique_index(:club_activity_refunds, [:stripe_refund_id])
    create index(:club_activity_refunds, [:status])
    create index(:club_activity_refunds, [:requested_at])

    execute "ALTER TABLE club_activity_refunds ADD CONSTRAINT refund_amount_positive CHECK (refund_amount > 0)"
  end

  def down do
    drop table(:club_activity_refunds)
    drop table(:club_activity_registrations)
    drop table(:external_users)
  end
end
