defmodule DhcWeb.Plugs.RequireSessionTest do
  use DhcWeb.ConnCase, async: true

  import Dhc.AuthFixtures
  alias Dhc.Repo

  import Ecto.Query

  @session_cookie "_dhc_session"

  # The 403 case needs a role-restricted route through the RequireSession
  # plug. We mount a throwaway test-only route via a test-scoped plug module
  # instead of adding a permanent route to the production router. The plug
  # is invoked directly on a conn built for an authenticated, role-bearing
  # principal; we assert the plug halts with 403 when the roles don't
  # intersect.
  #
  # This keeps the 401-vs-403 distinction observable at the plug seam
  # (the spec's primary test seam) without polluting the production router.

  describe "401 vs 403 distinction" do
    setup do
      auth_user_id = Ecto.UUID.generate()
      email = "plug-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      # Give only the "member" role — not in the admin set we'll require.
      Repo.insert_all("user_roles", [
        [principal_id: Ecto.UUID.dump!(auth_user_id), role: "member"]
      ])

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)
      {:ok, principal: principal, token: token}
    end

    test "returns 403 when the session is valid and active but lacks the required role",
         %{token: token} do
      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> DhcWeb.Plugs.RequireSession.call(roles: ~w(admin president))

      assert conn.halted
      assert conn.status == 403

      assert %{"errors" => %{"detail" => "Insufficient role"}} =
               Phoenix.json_library().decode!(conn.resp_body)
    end

    test "returns 401 (not 403) when there is no session at all" do
      conn =
        conn()
        |> DhcWeb.Plugs.RequireSession.call(roles: ~w(admin))

      assert conn.halted
      assert conn.status == 401
    end

    test "passes the session through when the role matches", %{token: token} do
      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> DhcWeb.Plugs.RequireSession.call(roles: ~w(member admin))

      refute conn.halted
      assert conn.assigns.current_session.principal.id
      assert "member" in conn.assigns.current_session.roles
    end
  end

  describe "tampered or expired cookie" do
    test "401 for a cookie whose signature does not verify" do
      conn =
        conn()
        |> Map.replace!(:secret_key_base, DhcWeb.Endpoint.config(:secret_key_base))
        |> put_req_cookie(@session_cookie, "garbage-signed-value")
        |> DhcWeb.Plugs.RequireSession.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "401 for a session token that has expired" do
      auth_user_id = Ecto.UUID.generate()
      email = "expired-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)
      # age_token matches the stored column value (SHA-256 digest since ALE-182).
      age_token(:crypto.hash(:sha256, token), -31, :day)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> DhcWeb.Plugs.RequireSession.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  defp put_signed_cookie(conn, key, value) do
    secret = DhcWeb.Endpoint.config(:secret_key_base)

    signer_conn =
      conn
      |> Map.replace!(:secret_key_base, secret)
      |> Plug.Conn.put_resp_cookie(key, value, sign: true, max_age: 30 * 24 * 60 * 60)

    signed_value = signer_conn.resp_cookies[key].value

    # The conn we hand to the plug must have the same secret_key_base so
    # `fetch_cookies(signed: [...])` can verify the signature.
    conn
    |> Map.replace!(:secret_key_base, secret)
    |> put_req_cookie(key, signed_value)
  end
end
