defmodule DhcWeb.InvitationsControllerTest do
  use DhcWeb.ConnCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @invitation_admin_roles ~w(admin president committee_coordinator)

  setup do
    original = %{
      auth_verifier: Application.get_env(:dhc, :auth_verifier),
      onboarding_stripe_adapter: Application.get_env(:dhc, :onboarding_stripe_adapter),
      onboarding_stripe_customer_result:
        Application.get_env(:dhc, :onboarding_stripe_customer_result),
      onboarding_stripe_result: Application.get_env(:dhc, :onboarding_stripe_result),
      onboarding_test_pid: Application.get_env(:dhc, :onboarding_test_pid)
    }

    OpenApiVerifier.install(
      generate_sub: true,
      roles: @invitation_admin_roles,
      role_email: "admin@example.com",
      tokens: %{
        "member-token" => %{email: "member@example.com", roles: ["member"]}
      }
    )

    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Test)
    Application.put_env(:dhc, :onboarding_stripe_customer_result, {:ok, "cus_accept"})
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn ->
      OpenApiVerifier.restore(original.auth_verifier)

      Enum.each(Map.delete(original, :auth_verifier), fn
        {key, nil} -> Application.delete_env(:dhc, key)
        {key, value} -> Application.put_env(:dhc, key, value)
      end)
    end)
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

    test "duplicate emails within one batch are accepted and enqueued verbatim",
         %{conn: conn} do
      # The controller does NOT dedup — duplicates pass through to the worker,
      # which processes each invite separately in its own transaction and
      # rejects any invite whose email already has a pending invitation
      # (surfaced as a per-invite failure in the processing log). A
      # regression that silently dropped duplicates at the controller layer
      # would change worker semantics (the second invite would no longer be
      # rejected as a duplicate and surface in the processing log).
      dup_invite = %{
        "firstName" => "Ada",
        "lastName" => "Lovelace",
        "email" => "ada@example.com",
        "phoneNumber" => "+353 1 000 0000",
        "dateOfBirth" => "1990-01-01"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations", %{"invites" => [dup_invite, dup_invite]})

      assert response = json_response(conn, 202)
      assert response["data"]["queued"] == true
      assert is_integer(response["data"]["job_id"])

      assert [%Oban.Job{args: args}] = all_enqueued(worker: Dhc.Invitations.BulkInviteWorker)
      assert [_, _] = args["invites"]
      assert args["invites"] == [dup_invite, dup_invite]
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
      assert Map.keys(invitation) |> Enum.sort() ==
               ~w(createdAt email expiresAt id pricingTier status)

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

  describe "DELETE /api/invitations" do
    test "deletes the requested invitations", %{conn: conn} do
      first_id = insert_invitation(email: "first@example.com")
      second_id = insert_invitation(email: "second@example.com")
      untouched_id = insert_invitation(email: "untouched@example.com")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> delete("/api/invitations", %{"invitationIds" => [first_id, second_id]})

      assert response(conn, 204) == ""
      refute Repo.get(Invitation, first_id)
      refute Repo.get(Invitation, second_id)
      assert Repo.get(Invitation, untouched_id)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = delete(conn, "/api/invitations", %{"invitationIds" => [Ecto.UUID.generate()]})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 when token lacks an invitation admin role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> delete("/api/invitations", %{"invitationIds" => [Ecto.UUID.generate()]})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 400 for an empty or invalid invitation id list", _context do
      for invitation_ids <- [[], ["not-a-uuid"]] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer admin-token")
          |> delete("/api/invitations", %{"invitationIds" => invitation_ids})

        assert %{"errors" => %{"detail" => "invitationIds must be a non-empty list of UUIDs"}} =
                 json_response(conn, 400)
      end
    end
  end

  describe "public invitation conversion endpoints" do
    test "GET /api/invitations/:id returns public-safe invitation state without PII", %{
      conn: conn
    } do
      invitation_id = insert_invitation(email: "pii@example.com")

      conn = get(conn, "/api/invitations/#{invitation_id}")

      assert %{
               "data" => %{
                 "id" => ^invitation_id,
                 "status" => "pending",
                 "invitationType" => "member",
                 "expiresAt" => _
               }
             } = json_response(conn, 200)

      refute Map.has_key?(json_response(conn, 200)["data"], "email")
      refute Map.has_key?(json_response(conn, 200)["data"], "dateOfBirth")
      refute Map.has_key?(json_response(conn, 200)["data"], "firstName")
      refute Map.has_key?(json_response(conn, 200)["data"], "lastName")
    end

    test "POST /api/invitations/:id/verify confirms credentials without returning bearer material",
         %{
           conn: conn
         } do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "verify@example.com", date_of_birth: ~D[1990-01-01])

      conn =
        post(conn, "/api/invitations/#{invitation_id}/verify", %{
          "email" => " VERIFY@example.com ",
          "dateOfBirth" => "1990-01-01"
        })

      assert %{"data" => %{"verified" => true}} = json_response(conn, 200)
      refute Map.has_key?(json_response(conn, 200)["data"], "verificationToken")
      assert get_resp_header(conn, "authorization") == []
    end

    test "POST /api/invitations/:id/verify rejects mismatched credentials", %{conn: conn} do
      invitation_id =
        insert_invitation(email: "verify@example.com", date_of_birth: ~D[1990-01-01])

      conn =
        post(conn, "/api/invitations/#{invitation_id}/verify", %{
          "email" => "wrong@example.com",
          "dateOfBirth" => "1990-01-01"
        })

      assert %{"errors" => %{"detail" => "Invalid invitation credentials"}} =
               json_response(conn, 422)
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

    test "resending a real pending invitation refreshes expiry and enqueues an email",
         %{conn: conn} do
      # The only existing resend test sends a non-existent email and asserts
      # `failed: 1` — the success path is untested, so a regression that
      # silently no-ops on a real invitation (e.g. the left-join query breaks,
      # or expire_for_resend stops firing) would stay green.
      email = "real@example.com"
      invitation_id = insert_invitation(email: email, status: "pending", seconds: 0)
      original = Repo.get(Invitation, invitation_id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations/resend", %{"emails" => [email]})

      assert %{"data" => %{"succeeded" => 1, "failed" => 0}} = json_response(conn, 202)

      # The invite-member email was enqueued for the real invitation.
      assert [%Oban.Job{args: args}] = all_enqueued(worker: Dhc.Email.Worker)
      assert args["email"] == email
      assert args["transactional_id"] == "inviteMember"

      # The resend refreshed the expiry window from +7 days to +1 day.
      refreshed = Repo.get(Invitation, invitation_id)
      assert refreshed.expires_at != original.expires_at

      expected = DateTime.add(DateTime.utc_now(), 1, :day) |> DateTime.truncate(:second)
      assert DateTime.diff(refreshed.expires_at, expected, :second) in -5..5
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

    test "resending never resurrects accepted or revoked invitations", %{conn: conn} do
      accepted_id = insert_invitation(email: "settled@example.com", status: "accepted")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations/resend", %{"emails" => ["settled@example.com"]})

      # The accepted invitation is not actionable, so the resend reports a
      # failure instead of silently re-arming it.
      assert %{"data" => %{"succeeded" => 0, "failed" => 1}} = json_response(conn, 202)
      refute_enqueued(worker: Dhc.Email.Worker)
      assert Repo.get!(Invitation, accepted_id).status == "accepted"
    end

    test "resending an email with an expired and a pending invitation refreshes only the pending one",
         %{conn: conn} do
      expired_id = insert_invitation(email: "mixed@example.com", status: "expired", seconds: 1)
      pending_id = insert_invitation(email: "mixed@example.com", status: "pending", seconds: 2)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/invitations/resend", %{"emails" => ["mixed@example.com"]})

      assert %{"data" => %{"succeeded" => 1, "failed" => 0}} = json_response(conn, 202)

      # One email for the address (the newest, pending invitation), and the
      # older expired row keeps its status — flipping both to pending would
      # violate invitations_email_pending_unique.
      assert [%Oban.Job{args: email_args}] = all_enqueued(worker: Dhc.Email.Worker)
      assert email_args["email"] == "mixed@example.com"

      assert %Invitation{status: "expired"} = Repo.get!(Invitation, expired_id)

      refreshed = Repo.get!(Invitation, pending_id)
      assert refreshed.status == "pending"

      expected = DateTime.add(DateTime.utc_now(), 1, :day) |> DateTime.truncate(:second)
      assert DateTime.diff(refreshed.expires_at, expected, :second) in -5..5
    end
  end

  # Inserts an invitation directly into the `invitations` table.
  #
  # ALE-162 (ADR 0010): issue time is side-effect free — the helper only
  # inserts the invitation row. No `auth.users` row, no `user_profiles` row,
  # and no Stripe customer is created at issue time; acceptance creates the
  # customer (the adapter returns the setup-configured "cus_accept").
  #
  # `search_text` is a `GENERATED ALWAYS AS (to_tsvector(email)) STORED`
  # column, so it is intentionally omitted — Postgres populates it from
  # `email` and the websearch query matches against it.
  #
  # `seconds` offsets `created_at` so cursor pagination tests get a
  # deterministic newest-first ordering without relying on insertion timing.
  defp insert_invitation(attrs) do
    id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    created_at = DateTime.add(now, Keyword.get(attrs, :seconds, 0), :second)
    expires_at = DateTime.add(created_at, 7, :day)

    {:ok, _invitation} =
      %Invitation{
        id: id,
        email: Keyword.get(attrs, :email, "test#{:rand.uniform(1_000_000)}@example.com"),
        prospective_principal_id: Keyword.get(attrs, :user_id, user_id),
        waitlist_id: Keyword.get(attrs, :waitlist_id),
        status: Keyword.get(attrs, :status, "pending"),
        expires_at: expires_at,
        created_at: created_at,
        created_by_principal_id: Keyword.get(attrs, :created_by),
        invitation_type: Keyword.get(attrs, :invitation_type, "member"),
        first_name: Keyword.get(attrs, :first_name, "Ada"),
        last_name: Keyword.get(attrs, :last_name, "Lovelace"),
        phone_number: Keyword.get(attrs, :phone_number, "+353810000000"),
        date_of_birth: Keyword.get(attrs, :date_of_birth, ~D[1990-01-01])
      }
      |> Repo.insert()

    id
  end

  defp insert_invitation_with_profile(attrs) do
    # ALE-162: the "with_profile" suffix is now historical — no profile is
    # created at issue time. The helper exists for acceptance tests that
    # need a pending invitation carrying the invite data plus an optional
    # waitlist entry. The name is kept so the pre-ALE-162 test sites that
    # referenced it continue to compile; the shape it returns is now
    # `{invitation_id, user_id}` (no `auth_user_id` / `profile_id`).
    email = Keyword.fetch!(attrs, :email)
    date_of_birth = Keyword.get(attrs, :date_of_birth, ~D[1990-01-01])
    user_id = Ecto.UUID.generate()
    invitation_id = Ecto.UUID.generate()

    waitlist_id =
      if Keyword.get(attrs, :waitlist, false) do
        id = Ecto.UUID.generate()
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.insert!(%Dhc.Waitlist.WaitlistEntry{
          id: id,
          email: email,
          status: "invited",
          initial_registration_date: now,
          last_status_change: now
        })

        id
      end

    expires_at = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    {:ok, _invitation} =
      %Invitation{
        id: invitation_id,
        email: email,
        prospective_principal_id: user_id,
        waitlist_id: waitlist_id,
        status: Keyword.get(attrs, :status, "pending"),
        expires_at: expires_at,
        invitation_type: Keyword.get(attrs, :invitation_type, "member"),
        first_name: Keyword.get(attrs, :first_name, "Ada"),
        last_name: Keyword.get(attrs, :last_name, "Lovelace"),
        phone_number: Keyword.get(attrs, :phone_number, "+353810000000"),
        date_of_birth: date_of_birth
      }
      |> Repo.insert()

    %{invitation_id: invitation_id, user_id: user_id, waitlist_id: waitlist_id}
  end
end
