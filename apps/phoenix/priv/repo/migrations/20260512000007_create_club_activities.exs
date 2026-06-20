defmodule Dhc.Repo.Migrations.CreateClubActivities do
  use Ecto.Migration

  def up do
    # ── club_activities ─────────────────────────────────────
    create table(:club_activities, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :text, null: false
      add :description, :text
      add :location, :text, null: false
      add :start_date, :timestamptz, null: false
      add :end_date, :timestamptz, null: false
      add :max_capacity, :integer, null: false
      add :price_member, :float, null: false
      add :price_non_member, :float, null: false
      add :is_public, :boolean, default: false
      add :refund_days, :integer, default: 3
      add :status, :club_activity_status, default: "planned"
      add :announce_discord, :boolean, default: false
      add :announce_email, :boolean, default: false
      add :created_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)

      # The `Dhc.Workshops.Workshop` schema declares
      # `timestamps(inserted_at: :created_at)` — the production `club_activities`
      # table (created by the frozen Supabase migration
      # `20250711204000_create_club_activities.sql`) names the column `created_at`,
      # not `inserted_at`. Mirror that here so Ecto query helpers that order by
      # `created_at` (e.g. the Workshop attendee read) match runtime behavior.
      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    execute "ALTER TABLE club_activities ADD CONSTRAINT max_capacity_positive CHECK (max_capacity > 0)"

    execute "ALTER TABLE club_activities ADD CONSTRAINT price_member_non_negative CHECK (price_member >= 0)"

    execute "ALTER TABLE club_activities ADD CONSTRAINT price_non_member_non_negative CHECK (price_non_member >= 0)"

    execute "ALTER TABLE club_activities ADD CONSTRAINT refund_days_non_negative CHECK (refund_days >= 0)"

    # ── club_activity_interest ──────────────────────────────
    create table(:club_activity_interest, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :club_activity_id,
          references(:club_activities, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, prefix: "auth", type: :uuid, on_delete: :delete_all),
        null: false

      # `club_activity_interest` also uses `created_at` in production (frozen
      # Supabase migration `20250714102710_create_club_activity_interest.sql`),
      # so mirror the column name — see the `club_activities` note above.
      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create unique_index(:club_activity_interest, [:club_activity_id, :user_id])
    create index(:club_activity_interest, [:club_activity_id])
    create index(:club_activity_interest, [:user_id])
    # `timestamps/1` adds `created_at`/`updated_at` (we rename `inserted_at` →
    # `created_at` above to match production), so index the actual column name.
    create index(:club_activity_interest, [:created_at])
  end

  def down do
    drop table(:club_activity_interest)
    drop table(:club_activities)
  end
end
