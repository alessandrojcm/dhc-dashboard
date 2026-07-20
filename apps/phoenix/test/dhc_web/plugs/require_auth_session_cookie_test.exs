defmodule DhcWeb.Plugs.RequireAuthSessionCookieTest do
  @moduledoc """
  ALE-164: the dashboard forwards the Phoenix `_dhc_session` cookie to Phoenix
  with `credentials: 'include'`. `RequireAuth` (the existing Supabase-JWT plug
  that still guards the data API until the ALE-163 cutover) must accept that
  cookie as an alternative to the bearer token and produce the same
  `current_user` shape controllers already read (`sub`, `email`, `roles`).

  These tests exercise the cookie path through the plug directly. The bearer
  path remains covered by `require_auth_test.exs`; here we assert the two
  paths are equivalent for the controller-visible shape, and that the cookie
  is preferred when both are present (the dashboard sends no bearer).
  """

  use DhcWeb.ConnCase, async: true

  import Dhc.AuthFixtures
  alias Dhc.Repo

  import Ecto.Query

  @session_cookie "_dhc_session"
  @admin_endpoint "/api/members"

  describe "cookie path produces the same current_user shape as the bearer path" do
    setup do
      auth_user_id = Ecto.UUID.generate()
      email = "cookie-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      # Give the member an admin role so we can route through the
      # members_admin_api pipeline and observe a 200 (vs 401/403).
      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "admin"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)
      {:ok, principal: principal, token: token}
    end

    test "authorizes a request that carries only the signed session cookie", %{
      token: token,
      conn: conn
    } do
      conn =
        conn
        |> put_signed_cookie(@session_cookie, token)
        |> get(@admin_endpoint)

      assert %{"data" => _} = json_response(conn, 200)
    end

    test "current_user carries sub, email, and roles from the session projection", %{
      token: token,
      principal: principal
    } do
      # Drive the plug directly so we can inspect assigns without depending
      # on a specific controller's rendering.
      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> DhcWeb.Plugs.RequireAuth.call([])

      refute conn.halted

      assert conn.assigns.current_user.sub == principal.id
      assert conn.assigns.current_user.email == principal.email
      assert "admin" in conn.assigns.current_user.roles
    end

    test "a member-only session is 403 through a role-restricted pipeline", %{
      principal: principal
    } do
      # Replace the admin role with member-only so the session is valid and
      # active but lacks the required role set of the members_admin_api
      # pipeline.
      auth_user_id = principal.id

      Repo.delete_all(
        from(ur in "user_roles", where: ur.user_id == type(^auth_user_id, Ecto.UUID))
      )

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "401 outcomes on the cookie path" do
    test "401 with no cookie and no bearer" do
      conn = conn() |> get(@admin_endpoint)
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "401 with a cookie whose signature does not verify" do
      conn =
        conn()
        |> Map.replace!(:secret_key_base, DhcWeb.Endpoint.config(:secret_key_base))
        |> put_req_cookie(@session_cookie, "garbage-signed-value")
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "401 for an expired session cookie" do
      auth_user_id = Ecto.UUID.generate()
      email = "expired-cookie-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)
      age_token(token, -31, :day)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "401 for a session whose Principal has no user_profile" do
      # A Principal exists and has a valid session, but no user_profiles row,
      # so the access projection is `{:error, :no_profile}`. The cookie path
      # must surface this as 401 (matching RequireSession's behavior).
      principal = principal_fixture()
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "401 for an inactive Principal" do
      auth_user_id = Ecto.UUID.generate()
      email = "inactive-cookie-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: false,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  describe "precedence between cookie and bearer" do
    # When both a valid cookie and a bearer token are present, the cookie
    # wins. The dashboard after ALE-164 sends only the cookie; a transition
    # client that still carries a stale Supabase bearer must not override the
    # authoritative session. We assert this by giving the bearer a different
    # identity (a fresh UUID) and confirming the controller sees the cookie's
    # principal, not the bearer's.

    @bearer_sub "00000000-0000-0000-0000-0000000000ee"

    # A bearer-verifier stub that returns a *different* sub. If the plug
    # consulted the bearer, current_user.sub would be this other UUID. The
    # UUID is fixed at the module level so the verifier module can compile
    # without needing to capture a setup binding.
    defmodule PrecedenceVerifier do
      def verify("other-bearer-token") do
        {:ok,
         %{
           sub: "00000000-0000-0000-0000-0000000000ee",
           email: "other@example.com",
           roles: ["admin"],
           raw: %{}
         }}
      end

      def verify(_), do: {:error, :invalid_token}
    end

    setup do
      auth_user_id = Ecto.UUID.generate()
      email = "prec-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "admin"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      original = Application.get_env(:dhc, :auth_verifier)
      Application.put_env(:dhc, :auth_verifier, PrecedenceVerifier)
      on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

      {:ok, principal: principal, token: token}
    end

    test "cookie identity wins when both cookie and bearer are present", %{
      token: token,
      principal: principal
    } do
      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> put_req_header("authorization", "Bearer other-bearer-token")
        |> DhcWeb.Plugs.RequireAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.sub == principal.id
      refute conn.assigns.current_user.sub == @bearer_sub
    end

    test "falls back to the bearer when no cookie is present" do
      conn =
        conn()
        |> put_req_header("authorization", "Bearer other-bearer-token")
        |> DhcWeb.Plugs.RequireAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.sub == @bearer_sub
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp put_signed_cookie(conn, key, value) do
    secret = DhcWeb.Endpoint.config(:secret_key_base)

    signer_conn =
      conn
      |> Map.replace!(:secret_key_base, secret)
      |> Plug.Conn.put_resp_cookie(key, value, sign: true, max_age: 30 * 24 * 60 * 60)

    signed_value = signer_conn.resp_cookies[key].value

    conn
    |> Map.replace!(:secret_key_base, secret)
    |> put_req_cookie(key, signed_value)
  end
end
