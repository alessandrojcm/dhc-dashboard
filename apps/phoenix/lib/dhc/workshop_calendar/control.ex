defmodule Dhc.WorkshopCalendar.Control do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "workshop_calendar_control" do
    field :paused, :boolean, default: false
  end
end
