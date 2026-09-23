defmodule Dhc.ClubCalendar.Holiday do
  @moduledoc """
  Ecto schema for the `club_calendar_holidays` table: one cached Irish
  bank-holiday fact per Europe/Dublin date (ALE-319).

  The date is the primary key. `name` is the English holiday name,
  `source_id` the OpenHolidays holiday id the row came from, and
  `fetched_at` when the row was last written by a fetch or refresh. A year
  counts as fetched exactly when it has rows; the refresh worker deletes a
  fetched year's dates the source no longer returns.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "club_calendar_holidays" do
    field :name, :string
    field :source_id, :string
    field :fetched_at, :utc_datetime_usec
  end

  @doc "Changeset for rows written by the OpenHolidays fetch and refresh paths."
  def changeset(holiday, attrs) do
    holiday
    |> cast(attrs, [:date, :name, :source_id, :fetched_at])
    |> validate_required([:date, :name, :source_id, :fetched_at])
  end
end
