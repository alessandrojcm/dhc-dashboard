defmodule DhcWeb.UserSocket do
  @moduledoc """
  Authenticated WebSocket socket for per-user realtime invalidation signals.

  The browser supplies the current Supabase access token through the Phoenix
  1.8 native `authToken` transport option, which Phoenix carries in the
  WebSocket subprotocol and exposes here as `connect_info[:auth_token]`.

  `connect/3` verifies that token through the configured `:auth_verifier`
  boundary (the same `Dhc.Auth.SupabaseJwt` verifier the HTTP API uses), and
  assigns the verified Supabase `sub` to the socket. Missing, invalid, expired,
  and verifier-error tokens reject the connection. The `:auth_verifier` seam is
  runtime-configured so socket tests substitute the verifier exactly like the
  HTTP auth tests do.

  `id/1` scopes the socket to the verified user as `"users_socket:<sub>"`, so
  the application could broadcast `"disconnect"` to terminate a user's sockets
  if server-initiated revocation is ever needed. The socket ID is NOT a
  substitute for channel join authorization: `NotificationChannel.join/3` still
  compares the requested topic suffix against the assigned `sub`.

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
         {:ok, claims} <- verifier().verify(token) do
      {:ok, assign(socket, :current_user, claims)}
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

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.sub}"

  defp verifier, do: Application.get_env(:dhc, :auth_verifier, Dhc.Auth.SupabaseJwt)
end
