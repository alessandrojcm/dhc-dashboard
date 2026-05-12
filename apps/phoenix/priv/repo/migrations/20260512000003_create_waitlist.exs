defmodule Dhc.Repo.Migrations.CreateWaitlist do
  use Ecto.Migration

  def up do
    # ── waitlist ──────────────────────────────────────────────
    # Final schema after normalization (personal info fields moved to user_profiles)
    create table(:waitlist, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :text, null: false
      add :status, :waitlist_status, null: false, default: "waiting"
      add :initial_registration_date, :timestamptz, default: fragment("NOW()")
      add :last_status_change, :timestamptz, default: fragment("NOW()")
      add :last_contacted, :timestamptz
      add :admin_notes, :text
    end

    create unique_index(:waitlist, [:email])
    create index(:waitlist, [:status])
    create index(:waitlist, [:initial_registration_date])

    # ── waitlist_status_history ─────────────────────────────
    create table(:waitlist_status_history, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :waitlist_id, references(:waitlist, type: :uuid, on_delete: :nothing)
      add :old_status, :waitlist_status
      add :new_status, :waitlist_status, null: false
      add :changed_at, :timestamptz, default: fragment("NOW()")
      add :changed_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)
      add :notes, :text
    end
  end

  def down do
    drop table(:waitlist_status_history)
    drop table(:waitlist)
  end
end
