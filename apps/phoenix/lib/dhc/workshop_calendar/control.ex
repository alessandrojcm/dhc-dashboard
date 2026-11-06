defmodule Dhc.WorkshopCalendar.Control do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "workshop_calendar_control" do
    field :activation_key, :string
    field :activated_at, :utc_datetime_usec
  end
end
