defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopIntakeCheckIn do
  @moduledoc """
  ALE-390: door check-in on an Intake — who checked the person in and when.

  Additive. Written only by `Dhc.BeginnersWorkshops.Commands` (`check_in`,
  `undo_check_in`) under the Beginners' Workshop → Intake lock. The record
  names a Principal, not a Staff row, so it stays when that person is later
  unassigned; principals are never deleted (`on_delete: :restrict`). Both
  columns are set together or not at all.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intakes) do
      add :checked_in_at, :utc_datetime_usec

      add :checked_in_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :restrict)
    end

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_check_in_check,
        check: "(checked_in_at IS NULL) = (checked_in_by_principal_id IS NULL)"
      )
    )
  end
end
