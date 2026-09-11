defmodule Dhc.Notifications.Notification do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "notifications" do
    field :principal_id, Ecto.UUID
    field :body, :string
    # ALE-287: application-supplied identity of the logical event, present only
    # for keyed callers. Unique per recipient where set, so a retried creation
    # is a no-op instead of a duplicate row.
    field :notification_key, :string
    field :created_at, :utc_datetime
    field :read_at, :utc_datetime
  end
end
