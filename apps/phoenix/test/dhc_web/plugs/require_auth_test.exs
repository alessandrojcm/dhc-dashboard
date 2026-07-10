defmodule DhcWeb.Plugs.RequireAuthTest do
  use DhcWeb.ConnCase, async: false

  # RequireAuth is exercised in pipeline context by routing through an
  # admin-guarded endpoint. `members_admin_api` requires one of several
  # committee roles; "admin" qualifies, "member" does not. GET /api/members
  # returns an empty list when no members are seeded, so a 200 here proves
  # the plug authorized the request — a rejection halts before the
  # controller and returns 401/403 instead.
  @admin_endpoint "/api/members"

  # A minimal verifier stub: tokens map to fixed claims. `roles` drives the
  # authorize/2 branch under test; everything else is fill.
  defmodule Verifier do
    def verify("admin-token") do
      {:ok, %{sub: Ecto.UUID.generate(), email: "admin@example.com", roles: ["admin"], raw: %{}}}
    end

    # #6: the multi-role case. "member" comes first, "admin" second.
    def verify("multi-role-token") do
      {:ok,
       %{
         sub: Ecto.UUID.generate(),
         email: "multi@example.com",
         roles: ["member", "admin"],
         raw: %{}
       }}
    end

    def verify("member-only-token") do
      {:ok,
       %{
         sub: Ecto.UUID.generate(),
         email: "member@example.com",
         roles: ["member"],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
    :ok
  end

  describe "multiple roles on one token (#6)" do
    test "a token carrying several roles is authorized when any role matches", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer multi-role-token")
        |> get(@admin_endpoint)

      # authorize/2 uses Enum.any?/2 over roles, so the second matching
      # role ("admin") authorizes even though "member" leads. A regression
      # that head-matches the first role would take "member", miss the
      # required set, and surface as 403 here.
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "a token whose roles do not intersect the required set is forbidden", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-only-token")
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "bearer prefix case-insensitivity (#7)" do
    test "accepts a lowercase 'bearer ' prefix", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "bearer admin-token")
        |> get(@admin_endpoint)

      # The second clause of bearer_token/1 (line 38) strips a lowercase
      # "bearer " prefix; the request reaches the verifier and is
      # authorized as admin.
      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  describe "empty bearer token (#7)" do
    test "rejects 'Bearer ' with an empty token via the guard", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> get(@admin_endpoint)

      # The `when token != ""` guard on both bearer clauses fails, so the
      # request falls through to `{:error, :missing_token}` and never
      # reaches the verifier.
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  describe "basic auth and header precedence (#8)" do
    test "rejects 'Authorization: Basic' as 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "a second Authorization header is not treated as a bearer", %{conn: conn} do
      # Only the first Authorization header is inspected. A trailing Bearer
      # header must not rescue a leading Basic header, so bearer_token/1
      # falls through to {:error, :missing_token} and returns 401.
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> prepend_req_headers([{"authorization", "Basic dXNlcjpwYXNz"}])
        |> get(@admin_endpoint)

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end
end
