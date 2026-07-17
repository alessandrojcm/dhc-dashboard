defmodule DhcWeb.NotificationChannel do
  @moduledoc """
  Per-user Notification invalidation channel.

  The browser joins `"notifications:<supabase-user-id>"`. `join/3` authorizes
  the join by comparing the requested topic suffix exactly against the
  verified `socket.assigns.current_user.sub` assigned by `UserSocket.connect/3`.
  A user may join only their own topic; cross-user joins return
  `{:error, %{reason: "unauthorized"}}`.

  The realtime contract is intentionally minimal:

    * topic  — `notifications:<supabase-user-id>` (the notification owner)
    * event  — `notification_created`
    * payload — `%{}` (empty; clients refetch authoritative state over HTTP)

  `Dhc.Notifications.Broadcaster` broadcasts that event to the owner's topic
  after a Notification is durably committed. Because the channel does not
  `intercept` the event, Phoenix's default behavior pushes the broadcast
  straight to the joined client via `handle_info(%Broadcast{...}, socket)`. No
  custom `handle_out/3` is required.

  The event is an invalidation signal only — never Notification data. Read-state
  changes are not broadcast; they converge through ordinary HTTP refetch.
  """

  use DhcWeb, :channel

  @impl true
  def join("notifications:" <> requested_sub, _payload, socket) do
    verified_sub = socket.assigns.current_user.sub

    if requested_sub == verified_sub do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Any other topic shape is not authorized. This clause is defensive: the
  # socket only routes "notifications:*" here, so it should not normally fire.
  def join(_topic, _payload, _socket) do
    {:error, %{reason: "unauthorized"}}
  end
end
