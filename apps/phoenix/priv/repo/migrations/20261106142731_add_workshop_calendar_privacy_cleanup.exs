defmodule Dhc.Repo.Migrations.AddWorkshopCalendarPrivacyCleanup do
  use Ecto.Migration

  def change do
    alter table(:workshop_calendar_recipients) do
      add :privacy_pending, :boolean, null: false, default: false
    end
  end
end
