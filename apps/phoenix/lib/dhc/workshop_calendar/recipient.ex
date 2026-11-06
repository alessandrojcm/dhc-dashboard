defmodule Dhc.WorkshopCalendar.Recipient do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workshop_calendar_recipients" do
    field :event_id, :binary_id
    field :place_id, :binary_id
    field :recipient, :string, redact: true
    field :previous_recipients, {:array, :string}, default: [], redact: true
    field :active, :boolean, default: true
    field :invited_generation, :integer
    field :requested_generation, :integer
    field :removed_generation, :integer
    field :failure, :string
    field :failure_episode, :binary_id
    field :alerted_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
