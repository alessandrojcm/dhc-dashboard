defmodule DhcWeb.UserSocket do
  @moduledoc """
  Authenticated WebSocket socket for per-user realtime invalidation signals.

  The browser supplies a credential through the Phoenix 1.8 native `authToken`
  transport option, which Phoenix carries in the WebSocket subprotocol and
  exposes here as `connect_info[:auth_token]`. Two credentials are accepted:

    * **Phoenix socket token** (ALE-164) — a short-lived, DB-backed opaque
      token the browser obtains by exchanging its HTTP-only `_dhc_session`
      cookie for a JS-readable token at `GET /api/auth/socket-token`. The
      browser cannot read the cookie directly, and `new WebSocket(url,
      protocols)` has no `withCredentials` so a cross-origin socket cannot
      send the cookie; the short-lived token is the credential the Phoenix
      JS client can pass via `authToken`. Verified through
      `Dhc.Auth.get_principal_by_socket_token/1`.
    * **Supabase access token** (transitional, until ALE-163) — verified
      through the configured `:auth_verifier` boundary (the same
      `Dhc.Auth.SupabaseJwt` verifier the HTTP API uses). This path stays
      available while the Supabase-JWT HTTP auth path is still live.

  Both paths assign a `current_user` map with `sub`, `email`, `roles`, and
  `raw` so the rest of the socket/channel pipeline does not branch on the
  credential source. `id/1` scopes the socket to the verified user as
  `"users_socket:<sub>"`.

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
         {:ok, claims} <- authenticate(token) do
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

  # Try the Phoenix socket token (DB-backed, short-lived) first. If it does
  # not decode or has no row, fall back to the Supabase-JWT verifier. This
  # keeps both paths available without the caller needing to know which
  # credential it is carrying — the browser after ALE-164 sends the socket
  # token, while any transition client still carrying a Supabase JWT keeps
  # working until ALE-163.
  defp authenticate(token) do
    with {:ok, decoded} <- safe_base64_decode(token),
         {:ok, principal} <- Dhc.Auth.get_principal_by_socket_token(decoded),
         {:ok, projection} <- Dhc.Auth.load_session_principal(principal),
         :ok <- require_active(projection) do
      {:ok, claims_from_projection(projection)}
    else
      :not_base64 -> verifier().verify(token)
      {:error, :invalid} -> verifier().verify(token)
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

  defp claims_from_projection(%{principal: principal, roles: roles}) do
    %{sub: principal.id, email: principal.email, roles: roles, raw: %{}}
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.sub}"

  defp verifier, do: Application.get_env(:dhc, :auth_verifier, Dhc.Auth.SupabaseJwt)
end
