defmodule Dhc.WorkshopCalendar.Event do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workshop_calendar_events" do
    field :source_kind, :string
    field :source_id, :binary_id
    field :audience, :string, default: "committee"
    field :revision, :integer, default: 1
    field :deleted, :boolean, default: false
    field :generation, :integer, default: 0
    field :event_id, :string
    field :calendar_id, :string
    field :create_requested, :boolean, default: false
    field :acknowledged, :map
    field :removal_completed, :boolean, default: false
    field :lease_token, :binary_id
    field :lease_until, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :failure, :string
    field :failure_episode, :binary_id
    field :alerted_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
