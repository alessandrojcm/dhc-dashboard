defmodule DhcWeb.Plugs.RequireAuth do
  @moduledoc """
  Requires a valid Supabase bearer token or a Phoenix Session cookie, and
  optionally one of a set of roles.

  ## ALE-164 — Phoenix Session cookie path

  The dashboard after ALE-164 forwards the signed `_dhc_session` cookie to
  Phoenix with `credentials: 'include'` and no longer sends a Supabase bearer
  token. Until the ALE-163 cutover retires `RequireAuth` entirely in favor of
  `RequireSession`, this plug accepts *either* credential:

    * **Cookie** (preferred when both are present) — the signed
      `_dhc_session` cookie is verified through
      `Dhc.Auth.get_principal_by_session_token/1` and projected through
      `Dhc.Auth.load_session_principal/1`. The projection's `principal.id`
      becomes `current_user.sub`, `principal.email` becomes
      `current_user.email`, and the projection's `roles` list becomes
      `current_user.roles`. This is the same shape controllers already read
      from the Supabase-JWT path, so no controller changes are required.
    * **Bearer** (fallback) — the Supabase JWT path is unchanged and is
      documented in the rest of this moduledoc.

  When both a valid cookie and a bearer are present, the cookie wins. The
  dashboard sends only the cookie; a transition client carrying a stale
  bearer must not override the authoritative session.

  ## Bearer path (Supabase JWT, transitional)

  Verified claims are assigned to `conn.assigns.current_user`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  @behaviour Plug

  @session_cookie "_dhc_session"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    required_roles = Keyword.get(opts, :roles, [])

    with {:ok, claims} <- authenticate(conn) do
      case authorize(claims, required_roles) do
        :ok -> assign(conn, :current_user, claims)
        {:error, :forbidden} -> forbidden(conn)
      end
    else
      {:error, :missing_token} -> unauthorized(conn, "Missing bearer token")
      {:error, :forbidden} -> forbidden(conn)
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  # ── Authentication ─────────────────────────────────────────────────────
  #
  # Try the session cookie first (preferred). If there is no cookie, fall
  # back to the bearer. If both are present and the cookie authenticates, the
  # cookie wins; if the cookie is present but invalid, we do NOT fall back to
  # the bearer — an invalid cookie is treated the same as an invalid bearer
  # (reject), which keeps the boundary unambiguous and prevents a stale
  # bearer from rescuing a revoked session.

  defp authenticate(conn) do
    conn = fetch_cookies(conn, signed: [@session_cookie])

    case conn.cookies[@session_cookie] do
      token when is_binary(token) and token != "" ->
        authenticate_with_session_token(token)

      _ ->
        authenticate_with_bearer(conn)
    end
  end

  defp authenticate_with_session_token(token) do
    with {:ok, principal} <- Dhc.Auth.get_principal_by_session_token(token),
         {:ok, projection} <- Dhc.Auth.load_session_principal(principal),
         :ok <- require_active(projection) do
      {:ok, claims_from_session(projection)}
    else
      {:error, :invalid} -> {:error, :invalid}
      {:error, :no_profile} -> {:error, :no_profile}
      {:error, :inactive} -> {:error, :inactive}
    end
  end

  # A Principal whose Member has no current club access is not an
  # authenticated dashboard session. This mirrors `RequireSession`'s 401
  # outcome for inactive Principals (per the spec) and prevents the role
  # check from turning "inactive" into a 403.
  defp require_active(%{is_active: true}), do: :ok
  defp require_active(_), do: {:error, :inactive}

  # `RequireSession` exposes the projection as
  # `%{principal: %Principal{}, roles: [...], is_active: boolean}`. Here we
  # re-shape it into the `current_user` map the controllers already read
  # (`sub`, `email`, `roles`). `raw` is left empty because the cookie path
  # has no JWT to carry — controllers must not depend on `raw` for the
  # session-cookie path (and the Supabase-JWT path keeps its own `raw`).
  defp claims_from_session(%{principal: principal, roles: roles}) do
    %{
      sub: principal.id,
      email: principal.email,
      roles: roles,
      raw: %{}
    }
  end

  defp authenticate_with_bearer(conn) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- verifier().verify(token) do
      {:ok, claims}
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> case do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      ["bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp authorize(_claims, []), do: :ok

  defp authorize(%{roles: roles}, required_roles) do
    if Enum.any?(roles, &(&1 in required_roles)), do: :ok, else: {:error, :forbidden}
  end

  defp verifier, do: Application.get_env(:dhc, :auth_verifier, Dhc.Auth.SupabaseJwt)

  defp unauthorized(conn, reason) do
    Logger.warning("[auth] request rejected: #{inspect(reason)}")

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
