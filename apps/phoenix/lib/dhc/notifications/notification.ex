defmodule Dhc.Notifications.Notification do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "notifications" do
    field :user_id, Ecto.UUID
    field :body, :string
    field :created_at, :utc_datetime
    field :read_at, :utc_datetime
  end
end
