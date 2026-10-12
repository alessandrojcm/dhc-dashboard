defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopIntakeHistory do
  @moduledoc """
  ALE-386: the Intake history — one row per console Intake command that did
  something (decline, resend link, rotate link, and the later Intake
  commands), with who ran it, when, and the coordinator's optional note.

  Additive. A repeated command that found the Intake already in its target
  state writes no row. The actor is a Principal (nulled if the Principal is
  ever deleted), so the record outlives a Staff assignment or a role.
  """

  use Ecto.Migration

  def change do
    create table(:beginners_workshop_intake_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :command, :text, null: false

      add :actor_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)

      add :note, :text
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create(index(:beginners_workshop_intake_events, [:intake_id, :occurred_at]))

    create(
      constraint(:beginners_workshop_intake_events, :beginners_workshop_intake_events_note_check,
        check: "note IS NULL OR (char_length(note) BETWEEN 1 AND 500)"
      )
    )
  end
end
