defmodule DhcWeb.Plugs.RequireSession do
  @moduledoc """
  Requires a valid Phoenix Session cookie and, optionally, one of a set of
  roles.

  This is the Phoenix-session counterpart to `DhcWeb.Plugs.RequireAuth` (the
  transitional Supabase-JWT plug). It is the boundary ALE-165 establishes for
  the new `/api/auth/*` and future migrated endpoints; existing endpoints
  stay on `RequireAuth` until the ALE-163 cutover.

  ## Outcomes (per the spec)

    * Missing / malformed / expired session token cookie → **401**
      `{"errors":{"detail":"Unauthorized"}}`. Unauthenticated.
    * Valid token but Principal has no `user_profiles` row, or `is_active` is
      false → **401**. A Principal whose Member has no current club access is
      not an authenticated dashboard session.
    * Valid token + active Principal but no required role matches → **403**
      `{"errors":{"detail":"Insufficient role"}}`. Unauthorized.
    * Otherwise: `conn.assigns.current_session` is set to
      `%{principal: %Principal{}, roles: [String.t()], is_active: true}` and
      the request proceeds.

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
  import Phoenix.Controller, only: [json: 2]

  require Logger

  @session_cookie "_dhc_session"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    required_roles = Keyword.get(opts, :roles, [])

    conn = fetch_cookies(conn, signed: [@session_cookie])

    with {:ok, token} <- session_token(conn),
         {:ok, principal} <- Dhc.Auth.get_principal_by_session_token(token),
         {:ok, projection} <- Dhc.Auth.load_session_principal(principal),
         :ok <- require_active(projection),
         :ok <- authorize(projection, required_roles) do
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

  defp require_active(%{is_active: true}), do: :ok
  defp require_active(_), do: {:error, :inactive}

  defp authorize(_projection, []), do: :ok

  defp authorize(%{roles: roles}, required_roles) do
    if Enum.any?(roles, &(&1 in required_roles)), do: :ok, else: {:error, :forbidden}
  end

  defp unauthorized(conn, reason) do
    Logger.warning("[auth] session rejected: #{inspect(reason)}")
    # Aggregate, non-personal telemetry — no email or principal id.
    :telemetry.execute([:dhc, :auth, :session, :rejected], %{reason: inspect(reason)}, %{})

    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Unauthorized"}})
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: "Insufficient role"}})
    |> halt()
  end
end
