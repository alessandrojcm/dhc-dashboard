defmodule Dhc.Repo.Migrations.CreateWorkshopCalendarEvents do
  use Ecto.Migration

  def change do
    # Additive deploy. No FK to a source: deletion obligations outlive it.
    create table(:workshop_calendar_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_kind, :text, null: false
      add :source_id, :binary_id, null: false
      add :audience, :text, null: false, default: "committee"
      add :revision, :bigint, null: false, default: 1
      add :deleted, :boolean, null: false, default: false
      add :generation, :integer, null: false, default: 0
      add :event_id, :text, null: false
      add :calendar_id, :text
      add :create_requested, :boolean, null: false, default: false
      add :acknowledged, :map
      add :removal_completed, :boolean, null: false, default: false
      add :lease_token, :binary_id
      add :lease_until, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :retry_at, :utc_datetime_usec
      add :failure, :text
      add :failure_episode, :binary_id
      add :alerted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workshop_calendar_events, [:source_kind, :source_id, :audience])
    create unique_index(:workshop_calendar_events, [:event_id])

    create constraint(:workshop_calendar_events, :workshop_calendar_event_identity,
             check:
               "source_kind IN ('workshop', 'beginners_workshop') AND audience IN ('committee', 'participant') AND generation >= 0 AND revision > 0 AND attempts >= 0"
           )

    create table(:workshop_calendar_control, primary_key: false) do
      add :id, :integer, primary_key: true
      add :paused, :boolean, null: false, default: false
    end

    create constraint(:workshop_calendar_control, :workshop_calendar_single_control,
             check: "id = 1"
           )

    execute "INSERT INTO workshop_calendar_control (id, paused) VALUES (1, false)",
            "DELETE FROM workshop_calendar_control WHERE id = 1"
  end
end
