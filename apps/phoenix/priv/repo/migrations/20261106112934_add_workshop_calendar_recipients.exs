defmodule Dhc.Repo.Migrations.AddWorkshopCalendarRecipients do
  use Ecto.Migration

  def change do
    # No source FK: entitlements and cleanup obligations outlive source rows.
    create table(:workshop_calendar_recipients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id,
          references(:workshop_calendar_events, type: :binary_id, on_delete: :delete_all),
          null: false

      add :place_id, :binary_id, null: false
      add :recipient, :text
      add :previous_recipients, {:array, :text}, null: false, default: []
      add :active, :boolean, null: false, default: true
      add :invited_generation, :integer
      add :requested_generation, :integer
      add :removed_generation, :integer
      add :failure, :text
      add :failure_episode, :binary_id
      add :alerted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workshop_calendar_recipients, [:event_id, :place_id])
  end
end
