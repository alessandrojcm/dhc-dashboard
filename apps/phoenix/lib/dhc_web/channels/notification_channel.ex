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

  `Dhc.Notifications.Broadcaster` broadcasts that event to the owner's
  canonical topic after a Notification is durably committed. For a channel
  joined on the canonical topic, Phoenix's default behavior pushes the
  broadcast straight to the client. A channel joined on the `self` alias has
  a *different* joined topic, so Phoenix's default handler ignores the
  broadcast: `join/3` therefore subscribes the channel process to the
  canonical topic and `handle_info/2` relays the event onto the alias (ALE-299
  fixed the alias silently never receiving anything).

  The event is an invalidation signal only — never Notification data. Read-state
  changes are not broadcast; they converge through ordinary HTTP refetch.
  """

  use DhcWeb, :channel

  alias Dhc.Notifications.Broadcaster

  @notification_created "notification_created"

  @impl true
  def join("notifications:self", _payload, socket) do
    # ALE-164: the browser cannot read its own id from the opaque socket
    # token, so it joins the `self` alias. Resolving to the verified sub is
    # the authorization — the client only ever receives its own topic's
    # broadcasts, and cross-user joins are impossible because the socket is
    # already authenticated to a single principal.
    #
    # The channel process is only auto-subscribed to its joined topic
    # (`notifications:self`), which nothing broadcasts on; subscribe it to the
    # canonical topic the broadcaster actually uses.
    :ok = Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(verified_sub(socket)))
    {:ok, socket}
  end

  def join("notifications:" <> requested_sub, _payload, socket) do
    if requested_sub == verified_sub(socket) do
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

  # A broadcast on the canonical topic arriving at a channel joined on the
  # `self` alias: Phoenix's default `%Broadcast{}` handler only matches when
  # the broadcast topic equals the joined topic, so relay it by hand. The
  # subscription above is scoped to the verified principal's topic, which is
  # what keeps this from ever relaying another user's signal.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: @notification_created, payload: payload},
        socket
      ) do
    push(socket, @notification_created, payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp verified_sub(socket), do: socket.assigns.current_session.principal.id
end
