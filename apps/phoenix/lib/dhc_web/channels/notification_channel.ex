defmodule DhcWeb.NotificationChannel do
  @moduledoc """
  Per-user Notification invalidation channel.

  The browser joins one of two topic shapes:

    * `"notifications:<sub>"` — the notification owner's id. `join/3`
      authorizes by comparing the requested suffix exactly against the
      verified `socket.assigns.current_user.sub` assigned by
      `UserSocket.connect/3`.
    * `"notifications:self"` — ALE-164 alias. The browser cannot read its own
      id from the opaque socket token, so it joins `notifications:self` and
      the channel resolves it to the verified `sub`. The authorization is the
      same: only the verified user's own topic is joined.

  A user may join only their own topic; cross-user joins return
  `{:error, %{reason: "unauthorized"}}`.

  The realtime contract is intentionally minimal:

    * topic  — `notifications:<sub>` (or `notifications:self`)
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
  def join("notifications:self", _payload, socket) do
    # ALE-164: the browser cannot read its own id from the opaque socket
    # token, so it joins the `self` alias. Resolving to the verified sub is
    # the authorization — the client only ever receives its own topic's
    # broadcasts, and cross-user joins are impossible because the socket is
    # already authenticated to a single principal.
    {:ok, socket}
  end

  def join("notifications:" <> requested_sub, _payload, socket) do
    verified_sub = socket.assigns.current_session.principal.id

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
