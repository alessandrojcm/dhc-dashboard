defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopAttendanceFinalisation do
  @moduledoc """
  ALE-391: Attendance Finalisation.

  Additive. `finalised_at` records when a workshop's attendance became final
  and `finalised_by_principal_id` who pressed Finish at the door (null when
  the automatic end-of-day pass finalised it). Both are written only by
  `Dhc.BeginnersWorkshops.Commands` together with `status = 'finalised'`.

  `frozen_name` snapshots each Staff member's name at finalisation, so the
  frozen Staff list stays the permanent record of who ran the workshop even
  after that person leaves the club and their profile changes.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshops) do
      add :finalised_at, :utc_datetime_usec

      add :finalised_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :restrict)
    end

    create(
      constraint(:beginners_workshops, :beginners_workshops_finalised_check,
        check: "(status = 'finalised') = (finalised_at IS NOT NULL)"
      )
    )

    alter table(:beginners_workshop_staff) do
      add :frozen_name, :text
    end
  end
end
