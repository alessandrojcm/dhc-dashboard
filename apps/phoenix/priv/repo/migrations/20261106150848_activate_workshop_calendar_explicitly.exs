defmodule Dhc.Repo.Migrations.ActivateWorkshopCalendarExplicitly do
  use Ecto.Migration

  def change do
    alter table(:workshop_calendar_control) do
      remove :paused, :boolean, default: false, null: false
      add :activation_key, :text
      add :activated_at, :utc_datetime_usec
    end
  end
end
