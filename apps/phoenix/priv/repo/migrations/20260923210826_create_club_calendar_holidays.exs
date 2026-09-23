defmodule Dhc.Repo.Migrations.CreateClubCalendarHolidays do
  @moduledoc """
  ALE-319: durable Irish bank-holiday cache owned by `Dhc.ClubCalendar`.

  One row per Europe/Dublin date: the holiday name, the OpenHolidays source
  id, and when the row was last fetched. The date is the primary key, so the
  fetch and refresh paths upsert on it and a year is "fetched" exactly when
  it has rows.
  """

  use Ecto.Migration

  def change do
    create table(:club_calendar_holidays, primary_key: false) do
      add :date, :date, primary_key: true
      add :name, :text, null: false
      add :source_id, :text, null: false
      add :fetched_at, :utc_datetime_usec, null: false
    end
  end
end
