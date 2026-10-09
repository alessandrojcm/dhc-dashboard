defmodule Dhc.Repo.Migrations.AddCorrectionToBeginnersWorkshopIntakeEvents do
  @moduledoc """
  ALE-393: an attendance correction's history row names the state the
  coordinator corrected the Intake to (`attended`, `no_show` or `deferred`),
  so the history reads "Attendance corrected to no-show". Every other
  command leaves it null.

  Additive: a nullable column and a CHECK that only `correct_attendance`
  rows carry it.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intake_events) do
      add :correction, :text
    end

    create(
      constraint(
        :beginners_workshop_intake_events,
        :beginners_workshop_intake_events_correction_check,
        check:
          "(command = 'correct_attendance') = (correction IS NOT NULL) AND " <>
            "(correction IS NULL OR correction IN ('attended', 'no_show', 'deferred'))"
      )
    )
  end
end
