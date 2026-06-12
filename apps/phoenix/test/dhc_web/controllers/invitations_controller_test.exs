defmodule DhcWeb.InvitationsControllerTest do
  use DhcWeb.ConnCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  defmodule Verifier do
    def verify("admin-token") do
      {:ok, %{sub: Ecto.UUID.generate(), email: "admin@example.com", roles: ["admin"], raw: %{}}}
    end

    def verify("member-token") do
      {:ok,
       %{sub: Ecto.UUID.generate(), email: "member@example.com", roles: ["member"], raw: %{}}}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
  end

  describe "POST /api/invitations" do
    test "returns 202 and enqueues the bulk invite worker", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations", %{
          "invites" => [
            %{
              "firstName" => "Ada",
              "lastName" => "Lovelace",
              "email" => "ada@example.com",
              "phoneNumber" => "+353 1 000 0000",
              "dateOfBirth" => "1990-01-01"
            }
          ]
        })

      response = json_response(conn, 202)
      assert response["data"]["queued"] == true
      assert is_integer(response["data"]["job_id"])

      assert_enqueued(worker: Dhc.Invitations.BulkInviteWorker)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = post(conn, "/api/invitations", %{"invites" => []})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks an invitation admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> post("/api/invitations", %{"invites" => []})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 400 for an empty invite list", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations", %{"invites" => []})

      assert %{"errors" => %{"detail" => "invites must be a non-empty list"}} =
               json_response(conn, 400)
    end
  end

  describe "POST /api/invitations/resend" do
    test "returns 202 with result counts", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations/resend", %{"emails" => ["missing@example.com"]})

      assert %{"data" => %{"succeeded" => 0, "failed" => 1}} = json_response(conn, 202)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = post(conn, "/api/invitations/resend", %{"emails" => ["ada@example.com"]})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks an invitation admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> post("/api/invitations/resend", %{"emails" => ["ada@example.com"]})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 400 for an empty email list", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations/resend", %{"emails" => []})

      assert %{"errors" => %{"detail" => "emails must be a non-empty list"}} =
               json_response(conn, 400)
    end
  end
end
