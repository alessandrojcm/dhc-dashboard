defmodule Dhc.Repo.Migrations.AddEndTimeToBeginnersWorkshops do
  use Ecto.Migration

  def change do
    # Historical schedules did not record a duration. Keep that fact unknown;
    # new schedules and reschedules are validated by the command boundary.
    alter table(:beginners_workshops) do
      add :end_time, :time
    end
  end
end
