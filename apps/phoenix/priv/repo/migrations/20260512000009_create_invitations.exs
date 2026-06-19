defmodule Dhc.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def up do
    # ── invitations ─────────────────────────────────────────
    create table(:invitations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :email, :text, null: false
      add :user_id, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)
      add :waitlist_id, references(:waitlist, type: :uuid, on_delete: :nothing)
      add :status, :invitation_status, null: false, default: "pending"

      add :expires_at, :timestamptz,
        null: false,
        default: fragment("NOW() + INTERVAL '7 days'")

      add :created_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)
      add :invitation_type, :text, null: false
      add :metadata, :map

      # Match the original Supabase schema (20250316135748_invitation_system.sql):
      # `created_at`/`updated_at`, NOT Ecto's default `inserted_at`. The
      # `Invitation` schema declares `timestamps(inserted_at: :created_at)`,
      # so the DB column must be `created_at` for the schema to read it.
      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    # search_text is a GENERATED ALWAYS AS STORED tsvector (matching Supabase's
    # 20251021100656_invitations_search_vector.sql). Ecto's `add/3` can't express
    # generated columns, so use raw SQL. Auto-populated from `email`; the
    # Invitation schema doesn't declare `search_text`, so inserts skip it.
    execute """
    ALTER TABLE invitations
    ADD COLUMN search_text tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(email, '')), 'B')
      ) STORED
    """

    create unique_index(:invitations, [:email, :status])
    create unique_index(:invitations, [:user_id])
    create index(:invitations, [:email], where: "status = 'pending'")

    # ── invitation_processing_logs ──────────────────────────
    create table(:invitation_processing_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id, references(:users, prefix: "auth", type: :uuid, on_delete: :delete_all),
        null: false

      add :total_count, :integer, null: false
      add :success_count, :integer, null: false
      add :failure_count, :integer, null: false
      add :results, :map, null: false
      add :created_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:invitation_processing_logs, [:user_id])
    create index(:invitation_processing_logs, [:created_at])

    execute """
    ALTER TABLE invitation_processing_logs
    ADD CONSTRAINT invitation_processing_logs_total_count_check
    CHECK (total_count = success_count + failure_count)
    """
  end

  def down do
    drop table(:invitation_processing_logs)
    drop table(:invitations)
  end
end
