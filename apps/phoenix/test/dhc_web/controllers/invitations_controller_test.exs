defmodule DhcWeb.InvitationsControllerTest do
  use DhcWeb.ConnCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Repo

  defmodule Verifier do
    @invitation_admin_roles ~w(admin president committee_coordinator)

    Enum.each(@invitation_admin_roles, fn role ->
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: Ecto.UUID.generate(),
           email: "admin@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end)

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

    test "accepts waitlist entry ids and enqueues them for worker resolution", %{conn: conn} do
      waitlist_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations", %{"invites" => [waitlist_id]})

      response = json_response(conn, 202)
      assert response["data"]["queued"] == true
      assert is_integer(response["data"]["job_id"])

      assert [%Oban.Job{args: args}] = all_enqueued(worker: Dhc.Invitations.BulkInviteWorker)
      assert args["invites"] == [waitlist_id]
      assert args["user"]["email"] == "admin@example.com"
      assert Ecto.UUID.cast(args["user"]["id"]) == {:ok, args["user"]["id"]}
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

  describe "GET /api/invitations" do
    test "allows all invitation admin roles", %{conn: _conn} do
      for role <- ~w(admin president committee_coordinator) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/invitations")

        assert %{"data" => %{"invitations" => [], "totalCount" => 0}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/invitations")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks an invitation admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/invitations")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns camelCase invitations and only pending/expired rows", %{conn: conn} do
      insert_invitation(email: "ada@example.com", status: "pending", seconds: 1)
      insert_invitation(email: "grace@example.com", status: "expired", seconds: 2)
      insert_invitation(email: "revoked@example.com", status: "revoked", seconds: 3)
      insert_invitation(email: "accepted@example.com", status: "accepted", seconds: 4)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations")

      assert %{
               "data" => %{
                 "invitations" => invitations,
                 "totalCount" => 2,
                 "limit" => 10,
                 "nextCursor" => next_cursor,
                 "previousCursor" => nil
               }
             } = json_response(conn, 200)

      # Newest-first by created_at desc: grace (2) before ada (1).
      assert Enum.map(invitations, & &1["email"]) == [
               "grace@example.com",
               "ada@example.com"
             ]

      invitation = hd(invitations)

      assert %{
               "id" => _,
               "email" => "grace@example.com",
               "status" => "expired",
               "expiresAt" => _,
               "createdAt" => _
             } = invitation

      # No extra fields leak into the DTO.
      assert Map.keys(invitation) |> Enum.sort() == ~w(createdAt email expiresAt id status)
      assert is_nil(next_cursor)
    end

    test "supports cursor next and previous pagination", %{conn: conn} do
      for index <- 1..11 do
        insert_invitation(
          email: "person#{String.pad_leading(Integer.to_string(index), 2, "0")}@example.com",
          status: "pending",
          seconds: index
        )
      end

      first_page =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", limit: 10)
        |> json_response(200)

      assert %{
               "data" => %{
                 "invitations" => first_entries,
                 "nextCursor" => next_cursor,
                 "previousCursor" => nil,
                 "totalCount" => 11
               }
             } = first_page

      # Default sort is createdAt desc — newest first.
      assert [%{"email" => "person11@example.com"} | _] = first_entries
      assert List.last(first_entries)["email"] == "person02@example.com"
      assert is_binary(next_cursor)

      second_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", limit: 10, cursor: next_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "invitations" => [%{"email" => "person01@example.com"}],
                 "nextCursor" => nil,
                 "previousCursor" => back_cursor
               }
             } = second_page

      back_page =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", limit: 10, cursor: back_cursor)
        |> json_response(200)

      assert %{
               "data" => %{
                 "invitations" => back_entries,
                 "previousCursor" => nil,
                 "nextCursor" => forward_cursor
               }
             } = back_page

      assert [%{"email" => "person11@example.com"} | _] = back_entries
      assert List.last(back_entries)["email"] == "person02@example.com"
      assert is_binary(forward_cursor)
    end

    test "supports sorting by allowed fields", %{conn: conn} do
      insert_invitation(email: "zoe@example.com", status: "expired", seconds: 1)
      insert_invitation(email: "amy@example.com", status: "pending", seconds: 2)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", sort: "email", direction: "asc")

      assert %{
               "data" => %{
                 "invitations" => [
                   %{"email" => "amy@example.com"},
                   %{"email" => "zoe@example.com"}
                 ]
               }
             } =
               json_response(conn, 200)
    end

    test "supports websearch text search", %{conn: conn} do
      # `invitations.search_text` is generated from the full email as a single
      # tsvector token, so websearch matches the complete email address (the
      # prior client-side `textSearch("search_text", ...)` behaved the same
      # way — partial local-parts did not match).
      insert_invitation(email: "needle@example.com", status: "pending", seconds: 1)
      insert_invitation(email: "haystack@example.com", status: "pending", seconds: 2)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", q: "needle@example.com")

      assert %{
               "data" => %{
                 "invitations" => [%{"email" => "needle@example.com"}],
                 "totalCount" => 1
               }
             } =
               json_response(conn, 200)
    end

    test "returns 400 for invalid or mismatched cursors", %{conn: conn} do
      invalid_cursor_conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(invalid_cursor_conn, 400)

      for index <- 1..11 do
        insert_invitation(
          email: "person#{String.pad_leading(Integer.to_string(index), 2, "0")}@example.com",
          status: "pending",
          seconds: index
        )
      end

      cursor =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/invitations", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
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

  # Inserts an invitation directly into the `invitations` table.
  #
  # `search_text` is a `GENERATED ALWAYS AS (to_tsvector(email)) STORED`
  # column, so it is intentionally omitted — Postgres populates it from
  # `email` and the websearch query matches against it.
  #
  # `seconds` offsets `created_at` so cursor pagination tests get a
  # deterministic newest-first ordering without relying on insertion timing.
  defp insert_invitation(attrs) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    created_at = DateTime.add(now, Keyword.get(attrs, :seconds, 0), :second)
    expires_at = DateTime.add(created_at, 7, :day)

    # invitations via the Invitation schema — Ecto handles the `created_at`
    # timestamp mapping (the schema declares `timestamps(inserted_at: :created_at)`),
    # autodumps the :binary_id PK, and skips the generated `search_text` column
    # (not a schema field; Postgres auto-populates it from `email`). Set
    # `created_at` explicitly so the `seconds` offset gives deterministic
    # newest-first ordering for cursor pagination — Ecto only auto-fills
    # `inserted_at`/`created_at` when it's nil.
    {:ok, _invitation} =
      %Invitation{
        id: id,
        email: Keyword.get(attrs, :email, "test#{:rand.uniform(1_000_000)}@example.com"),
        status: Keyword.get(attrs, :status, "pending"),
        expires_at: expires_at,
        created_at: created_at,
        invitation_type: Keyword.get(attrs, :invitation_type, "member")
      }
      |> Repo.insert()

    id
  end
end
