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
  scopes the socket to the verified Principal.

  Only `notifications:*` topics are routed here, and long polling is disabled at
  the endpoint mount. See `docs/secure-phoenix-channel-browser-integration.md`
  and `docs/phoenix-notification-realtime-migration-spec.md`.
  """

  use Phoenix.Socket

  require Logger

  alias DhcWeb.NotificationChannel

  ## Channels

  channel "notifications:*", NotificationChannel

  ## Authentication

  @impl true
  def connect(_params, socket, connect_info) do
    with token when is_binary(token) and token != "" <- connect_info[:auth_token],
         {:ok, projection} <- authenticate(token) do
      {:ok, assign(socket, :current_session, projection)}
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

  defp authenticate(token) do
    with {:ok, decoded} <- safe_base64_decode(token),
         {:ok, principal} <- Dhc.Auth.get_principal_by_socket_token(decoded),
         {:ok, projection} <- Dhc.Auth.load_session_principal(principal),
         :ok <- require_active(projection) do
      {:ok, projection}
    else
      :not_base64 -> {:error, :invalid}
      {:error, :invalid} -> {:error, :invalid}
      {:error, :no_profile} -> {:error, :no_profile}
      {:error, :inactive} -> {:error, :inactive}
    end
  end

  # A Principal whose Member has no current club access is not an
  # authenticated dashboard session. Mirrors the `RequireSession` /
  # `RequireAuth` cookie-path 401 outcome for inactive Principals.
  defp require_active(%{is_active: true}), do: :ok
  defp require_active(_), do: {:error, :inactive}

  defp safe_base64_decode(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :not_base64
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_session.principal.id}"
end
