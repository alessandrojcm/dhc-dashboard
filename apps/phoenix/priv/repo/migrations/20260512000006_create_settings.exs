defmodule Dhc.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def up do
    create table(:settings, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :key, :text, null: false
      add :value, :text, null: false
      add :type, :setting_type, null: false
      add :description, :text
      add :updated_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)

      # Production Supabase uses `created_at`/`updated_at` (see the original
      # `20241213134629_create_settings_table.sql`). Mirror that here rather
      # than the default `inserted_at` so the Ecto schema and downstream reads
      # align with production column names.
      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    # Unique index on :key also serves lookups — a second non-unique index on
    # the same column is redundant and collides on the generated index name.
    create unique_index(:settings, [:key])

    execute """
    ALTER TABLE settings
    ADD CONSTRAINT valid_boolean_values CHECK (
      type != 'boolean' OR value IN ('true', 'false')
    )
    """

    # Seed default settings. The table has NOT NULL `created_at`/`updated_at`
    # from `timestamps/1`, so the seed must populate them explicitly.
    execute """
    INSERT INTO settings (key, value, type, description, created_at, updated_at) VALUES
      ('waitlist_open', 'false', 'boolean', 'Controls whether the waitlist is currently accepting new members', NOW(), NOW()),
      ('hema_insurance_form_link', '', 'text', 'Link to the HEMA insurance form for members', NOW(), NOW()),
      ('subscription_max_pause_months', '6', 'text', 'Maximum months a subscription can be paused', NOW(), NOW()),
      ('subscription_min_pause_days', '1', 'text', 'Minimum days a subscription can be paused', NOW(), NOW())
    """
  end

  def down do
    drop table(:settings)
  end
end
