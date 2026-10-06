defmodule DhcWeb.UserSocket do
  @moduledoc """
  Authenticated WebSocket socket for per-user realtime invalidation signals.

  The browser supplies a credential through the Phoenix 1.8 native `authToken`
  transport option, which Phoenix carries in the WebSocket subprotocol and
  exposes here as `connect_info[:auth_token]`:

    * **Phoenix socket token** (ALE-164) — a short-lived, DB-backed opaque
      token the browser obtains by exchanging its HTTP-only `_dhc_session`
      cookie for a JS-readable token at `GET /api/auth/socket-token`. The
      browser cannot read the cookie directly, and `new WebSocket(url,
      protocols)` has no `withCredentials` so a cross-origin socket cannot
      send the cookie; the short-lived token is the credential the Phoenix
      JS client can pass via `authToken`. Verified through
      `Dhc.Auth.get_principal_by_socket_token/1`.
  The verified Session projection is assigned as `current_session`. `id/1`
  scopes the socket to the verified Principal and lets access revocation
  disconnect every established socket for that Principal.

  Only `notifications:*` topics are routed here, and long polling is disabled at
  the endpoint mount. See `docs/secure-phoenix-channel-browser-integration.md`
  and `docs/phoenix-notification-realtime-migration-spec.md`.
  """

  use Phoenix.Socket

  defoverridable init: 1, handle_in: 2

  require Logger

  alias DhcWeb.NotificationChannel

  ## Channels

  channel "notifications:*", NotificationChannel

  ## Authentication

  @doc false
  def socket_id(principal_id), do: Dhc.Auth.socket_topic(principal_id)

  @doc "Disconnects every established socket for an Authentication Principal."
  def disconnect(principal_id) do
    Dhc.Auth.disconnect_sockets(principal_id)
  end

  @impl true
  def connect(_params, socket, connect_info) do
    with token when is_binary(token) and token != "" <- connect_info[:auth_token],
         {:ok, projection, reference} <- authenticate(token) do
      {:ok,
       socket
       |> assign(:current_session, projection)
       |> assign(:socket_reference, reference)}
    else
      # Missing/empty token: reject without logging token contents.
      token when token in [nil, ""] ->
        :error

      # Verifier rejected the token (invalid, expired, or verifier error).
      {:error, reason} ->
        # Log the rejection reason without exposing the token. The reason is
        # an atom/term from the verifier boundary; it never carries the token
        # itself, so it is safe to inspect.
        Logger.warning("[socket] connection rejected: #{inspect(reason)}")
        :error
    end
  end

  # Phoenix subscribes the transport to its socket id in init/1, after
  # connect/3. Recheck only AFTER that subscription: a revocation before it
  # rejects initialization, and one after it reaches the transport mailbox.
  @impl true
  def init(state) do
    {:ok, {transport_state, socket}} = super(state)

    case Dhc.Auth.get_socket_projection_by_reference(socket.assigns.socket_reference) do
      {:ok, projection, _reference} ->
        {:ok, {transport_state, assign(socket, :current_session, projection)}}

      {:error, _reason} ->
        send(self(), %Phoenix.Socket.Broadcast{event: "disconnect"})
        {:ok, {transport_state, assign(socket, :authentication_revoked, true)}}
    end
  end

  @impl true
  def handle_in(_message, {_state, %{assigns: %{authentication_revoked: true}}} = state) do
    Phoenix.Socket.__info__(%Phoenix.Socket.Broadcast{event: "disconnect"}, state)
  end

  def handle_in(message, state), do: super(message, state)

  defp authenticate(token) do
    with {:ok, decoded} <- safe_base64_decode(token),
         {:ok, projection, reference} <- Dhc.Auth.get_socket_projection(decoded) do
      {:ok, projection, reference}
    else
      :not_base64 -> {:error, :invalid}
      {:error, :invalid} -> {:error, :invalid}
      {:error, :no_profile} -> {:error, :no_profile}
      {:error, :inactive} -> {:error, :inactive}
    end
  end

  defp safe_base64_decode(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :not_base64
    end
  end

  @impl true
  def id(socket), do: socket_id(socket.assigns.current_session.principal.id)
end
