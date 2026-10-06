defmodule DhcWeb.Plugs.RequireSession do
  @moduledoc """
  Requires a valid Phoenix Session cookie and, optionally, a capability
  (`plug RequireSession, capability: :"inventory.manage"`).

  This is the sole authenticated HTTP boundary after the ALE-163 cutover.

  ## Outcomes (per the spec)

    * Missing / malformed / expired session token cookie → **401**
      `{"errors":{"detail":"Unauthorized"}}`. Unauthenticated.
    * Valid token but Principal has no `user_profiles` row, or `is_active` is
      false → **401**. A Principal whose Member has no current club access is
      not an authenticated dashboard session.
    * Valid token + active Principal that does not hold the capability →
      **403** `{"errors":{"detail":"Insufficient role"}}`. Unauthorized.
      `Dhc.Auth.Capabilities` alone decides; the router names no roles.
    * Otherwise: `conn.assigns.current_session` is set to
      `%{principal: %Principal{}, roles: [String.t()], capabilities:
      [String.t()], is_active: true}` and the request proceeds.

  Owner-scoped capabilities need a resource, so they are rejected at
  `init/1`: controllers check those with `Dhc.Auth.Capabilities.authorize/3`.

  ## Cookie contract

  The session token is read from the `_dhc_session` cookie (signed by the
  Phoenix endpoint). Browser clients send it with `credentials: 'include'`;
  SvelteKit SSR/remote forwards it. The cookie attributes (Secure, HttpOnly,
  SameSite=Lax, domain `.dublinhemaclub.com`, 30-day max-age) are set on
  login by the controller. The signed-cookie verification happens via
  `Plug.Conn.fetch_cookies/2`; an invalid signature yields no session token,
  which is the same as missing → 401.
  """

  @behaviour Plug

  import Plug.Conn

  alias Dhc.Auth.Capabilities
  alias DhcWeb.Problem

  require Logger

  @session_cookie "_dhc_session"

  @impl Plug
  def init(opts) do
    case Keyword.get(opts, :capability) do
      nil ->
        opts

      capability ->
        unless Capabilities.exists?(capability) do
          raise ArgumentError, "unknown capability #{inspect(capability)}"
        end

        if Capabilities.owner_scoped?(capability) do
          raise ArgumentError,
                "#{inspect(capability)} is owner-scoped; authorize it in the controller"
        end

        opts
    end
  end

  @impl Plug
  def call(conn, opts) do
    capability = Keyword.get(opts, :capability)

    conn = fetch_cookies(conn, signed: [@session_cookie])

    with {:ok, token, projection} <- authenticate(conn),
         :ok <- Capabilities.authorize(projection, capability) do
      conn
      |> assign(:current_session, projection)
      |> assign(:current_session_token, token)
    else
      {:error, :missing_token} -> unauthorized(conn, "Missing session")
      {:error, :invalid} -> unauthorized(conn, "Invalid session")
      {:error, :no_profile} -> unauthorized(conn, "Inactive principal")
      {:error, :inactive} -> unauthorized(conn, "Inactive principal")
      {:error, :forbidden} -> forbidden(conn)
    end
  end

  defp session_token(conn) do
    case conn.cookies[@session_cookie] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp authenticate(conn) do
    with {:ok, token} <- session_token(conn),
         {:ok, projection} <- Dhc.Auth.get_session_projection(token) do
      {:ok, token, projection}
    else
      {:error, :missing_token} -> test_projection(conn)
      error -> error
    end
  end

  if Mix.env() == :test do
    defp test_projection(conn), do: DhcWeb.SessionTestAdapter.projection(conn)
  else
    defp test_projection(_conn), do: {:error, :missing_token}
  end

  defp unauthorized(conn, reason) do
    Logger.warning("[auth] session rejected: #{inspect(reason)}")
    # Aggregate, non-personal telemetry — no email or principal id.
    :telemetry.execute([:dhc, :auth, :session, :rejected], %{reason: inspect(reason)}, %{})

    Problem.send_reason(conn, :unauthorized)
  end

  defp forbidden(conn), do: Problem.send_reason(conn, :forbidden)
end
