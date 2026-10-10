defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopStaff do
  @moduledoc """
  ALE-379: the Staff of a Beginners' Workshop — one coach and any number of
  assistants, each a Principal.

  Additive. Rows are written only by `Dhc.BeginnersWorkshops.Commands`
  (`set_staff`, and `schedule_workshop` with optional Staff) under the
  Beginners' Workshop lock. A row is never updated: a change of role is a
  delete and a new row, so a row id names exactly one assignment and keys its
  "assigned"/"unassigned" Notifications.

  Principals are never deleted, and `on_delete: :restrict` keeps it that way
  for a Staff record (spec story 18: the Staff list is the permanent record of
  who ran a workshop).
  """

  use Ecto.Migration

  def change do
    create table(:beginners_workshop_staff, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workshop_id,
          references(:beginners_workshops, type: :binary_id, on_delete: :restrict),
          null: false

      add :principal_id, references(:principals, type: :binary_id, on_delete: :restrict),
        null: false

      add :role, :text, null: false

      add :assigned_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      unique_index(:beginners_workshop_staff, [:workshop_id, :principal_id],
        name: :beginners_workshop_staff_workshop_principal_unique
      )
    )

    create(
      unique_index(:beginners_workshop_staff, [:workshop_id],
        where: "role = 'coach'",
        name: :beginners_workshop_staff_one_coach
      )
    )

    create(index(:beginners_workshop_staff, [:principal_id]))

    create(
      constraint(:beginners_workshop_staff, :beginners_workshop_staff_role_check,
        check: "role IN ('coach', 'assistant')"
      )
    )
  end
end
