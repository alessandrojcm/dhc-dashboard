defmodule Dhc.Repo.Migrations.CreateTrainingCalendarGrants do
  use Ecto.Migration

  def change do
    # No source FK: a deleted or unlinked profile must not erase an owed revocation.
    create table(:training_calendar_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :calendar_id, :text, null: false
      add :email, :citext, null: false
      add :rule_id, :text
      add :etag, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:training_calendar_grants, [:calendar_id, :email])

    create constraint(:training_calendar_grants, :training_calendar_grants_acknowledgment,
             check: "(rule_id IS NULL) = (etag IS NULL)"
           )
  end
end
