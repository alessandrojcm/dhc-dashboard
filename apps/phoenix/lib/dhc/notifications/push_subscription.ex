defmodule Dhc.Notifications.PushSubscription do
  @moduledoc """
  ALE-299: one browser installation a member opted into Web Push from.

  The row is the browser's `PushSubscription` (endpoint + `p256dh` public key +
  `auth` secret) bound to the principal who was signed in when it was
  registered. The endpoint is the identity: the push service mints one per
  browser installation, and it is globally unique here so a re-registration
  from the same browser reassigns the row instead of stacking a second one.

  `p256dh` and `auth` are encryption material for that browser and never
  leave the server. The API renders only `id` and `createdAt`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "notification_push_subscriptions" do
    field :principal_id, Ecto.UUID
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
