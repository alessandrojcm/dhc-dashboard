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

      timestamps(type: :timestamptz)
    end

    create unique_index(:settings, [:key])
    create index(:settings, [:key])

    execute """
    ALTER TABLE settings
    ADD CONSTRAINT valid_boolean_values CHECK (
      type != 'boolean' OR value IN ('true', 'false')
    )
    """

    # Seed default settings
    execute """
    INSERT INTO settings (key, value, type, description) VALUES
      ('waitlist_open', 'false', 'boolean', 'Controls whether the waitlist is currently accepting new members'),
      ('hema_insurance_form_link', '', 'text', 'Link to the HEMA insurance form for members'),
      ('subscription_max_pause_months', '6', 'text', 'Maximum months a subscription can be paused'),
      ('subscription_min_pause_days', '1', 'text', 'Minimum days a subscription can be paused')
    """
  end

  def down do
    drop table(:settings)
  end
end
