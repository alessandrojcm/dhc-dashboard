defmodule DhcWeb.InvitationsControllerTest do
  use DhcWeb.ConnCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

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

  defmodule PaymentProcessor do
    def complete(attrs) do
      send(Application.fetch_env!(:dhc, :invitation_payment_test_pid), {:stripe_complete, attrs})
      Application.get_env(:dhc, :invitation_payment_result, :ok)
    end
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    original_payment_processor = Application.get_env(:dhc, :invitation_payment_processor)
    original_payment_result = Application.get_env(:dhc, :invitation_payment_result)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    Application.put_env(:dhc, :invitation_payment_processor, PaymentProcessor)
    Application.put_env(:dhc, :invitation_payment_result, :ok)
    Application.put_env(:dhc, :invitation_payment_test_pid, self())

    on_exit(fn ->
      Application.put_env(:dhc, :auth_verifier, original)
      Application.put_env(:dhc, :invitation_payment_processor, original_payment_processor)

      if original_payment_result do
        Application.put_env(:dhc, :invitation_payment_result, original_payment_result)
      else
        Application.delete_env(:dhc, :invitation_payment_result)
      end

      Application.delete_env(:dhc, :invitation_payment_test_pid)
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
      # which processes each invite separately in its own transaction. A
      # regression that silently dropped duplicates at the controller layer
      # would change worker semantics (the second invite would no longer fail
      # at Supabase user creation and surface in the processing log).
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
      assert length(args["invites"]) == 2
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

  describe "public invitation conversion endpoints" do
    test "GET /api/invitations/:id returns public-safe invitation state without PII", %{
      conn: conn
    } do
      %{invitation_id: invitation_id} = insert_invitation_with_profile(email: "pii@example.com")

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

    test "POST /api/invitations/:id/verify returns an opaque token for matching credentials", %{
      conn: conn
    } do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "verify@example.com", date_of_birth: ~D[1990-01-01])

      conn =
        post(conn, "/api/invitations/#{invitation_id}/verify", %{
          "email" => " VERIFY@example.com ",
          "dateOfBirth" => "1990-01-01"
        })

      assert %{"data" => %{"verified" => true, "verificationToken" => token}} =
               json_response(conn, 200)

      assert is_binary(token)
      assert byte_size(token) > 20
    end

    test "POST /api/invitations/:id/verify rejects mismatched credentials", %{conn: conn} do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "verify@example.com", date_of_birth: ~D[1990-01-01])

      conn =
        post(conn, "/api/invitations/#{invitation_id}/verify", %{
          "email" => "wrong@example.com",
          "dateOfBirth" => "1990-01-01"
        })

      assert %{"errors" => %{"detail" => "Invalid invitation credentials"}} =
               json_response(conn, 422)
    end

    test "POST /api/invitations/:id/accept atomically creates member state", %{conn: conn} do
      %{auth_user_id: user_id, profile_id: profile_id, invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "accept@example.com", waitlist: true)

      {:ok, token} =
        Dhc.Invitations.issue_verification_token(
          invitation_id,
          "accept@example.com",
          ~D[1990-01-01]
        )

      conn =
        post(conn, "/api/invitations/#{invitation_id}/accept", %{
          "verificationToken" => token,
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"data" => %{"accepted" => true, "memberId" => ^user_id}} = json_response(conn, 200)

      assert_receive {:stripe_complete,
                      %{
                        customer_id: "cus_accept",
                        confirmation_token: "ctok_test",
                        coupon_code: nil,
                        invitation_id: ^invitation_id
                      }}

      assert Repo.get!(Invitation, invitation_id).status == "accepted"

      member = Repo.get!(MemberProfile, user_id)
      assert member.user_profile_id == profile_id
      assert member.next_of_kin_name == "Ada Lovelace"
      assert member.insurance_form_submitted == true
      assert Repo.get!(UserProfile, profile_id).is_active == true

      assert Repo.exists?(
               from r in Dhc.Auth.UserRole, where: r.user_id == ^user_id and r.role == "member"
             )

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "accept@example.com",
                 select: w.status
             ) == "joined"
    end

    test "POST /api/invitations/:id/accept rolls back when Stripe payment fails", %{conn: conn} do
      %{profile_id: profile_id, invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "stripe-fail@example.com", waitlist: true)

      Application.put_env(:dhc, :invitation_payment_result, {:error, :card_declined})

      {:ok, token} =
        Dhc.Invitations.issue_verification_token(
          invitation_id,
          "stripe-fail@example.com",
          ~D[1990-01-01]
        )

      conn =
        post(conn, "/api/invitations/#{invitation_id}/accept", %{
          "verificationToken" => token,
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_declined"
        })

      assert %{"errors" => %{"detail" => "Payment could not be completed"}} =
               json_response(conn, 402)

      assert_receive {:stripe_complete, %{confirmation_token: "ctok_declined"}}
      assert Repo.get!(Invitation, invitation_id).status == "pending"
      assert Repo.get!(UserProfile, profile_id).is_active == false
      refute Repo.exists?(from m in MemberProfile, where: m.user_profile_id == ^profile_id)
    end

    test "POST /api/invitations/:id/accept rejects blank required fields before mutating", %{
      conn: conn
    } do
      %{profile_id: profile_id, invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "blank-accept@example.com", waitlist: true)

      {:ok, token} =
        Dhc.Invitations.issue_verification_token(
          invitation_id,
          "blank-accept@example.com",
          ~D[1990-01-01]
        )

      conn =
        post(conn, "/api/invitations/#{invitation_id}/accept", %{
          "verificationToken" => token,
          "nextOfKinName" => "  ",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"errors" => %{"detail" => "acceptance payload is invalid"}} =
               json_response(conn, 400)

      assert Repo.get!(Invitation, invitation_id).status == "pending"
      assert Repo.get!(UserProfile, profile_id).is_active == false

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "blank-accept@example.com",
                 select: w.status
             ) == "invited"

      refute_receive {:stripe_complete, _attrs}
    end

    test "POST /api/invitations/:id/accept rolls back when member creation fails", %{conn: conn} do
      %{auth_user_id: user_id, profile_id: profile_id, invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "rollback@example.com", waitlist: true)

      Repo.insert!(%MemberProfile{
        id: user_id,
        user_profile_id: profile_id,
        next_of_kin_name: "Existing Member",
        next_of_kin_phone: "+353 1 999 9999",
        preferred_weapon: [],
        membership_start_date: DateTime.utc_now() |> DateTime.truncate(:second),
        insurance_form_submitted: true,
        additional_data: %{}
      })

      {:ok, token} =
        Dhc.Invitations.issue_verification_token(
          invitation_id,
          "rollback@example.com",
          ~D[1990-01-01]
        )

      conn =
        post(conn, "/api/invitations/#{invitation_id}/accept", %{
          "verificationToken" => token,
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"errors" => %{"detail" => "Invitation cannot be accepted"}} =
               json_response(conn, 422)

      assert Repo.get!(Invitation, invitation_id).status == "pending"
      assert Repo.get!(UserProfile, profile_id).is_active == false

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "rollback@example.com",
                 select: w.status
             ) == "invited"

      refute_receive {:stripe_complete, _attrs}
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
        user_id: Keyword.get(attrs, :user_id),
        waitlist_id: Keyword.get(attrs, :waitlist_id),
        status: Keyword.get(attrs, :status, "pending"),
        expires_at: expires_at,
        created_at: created_at,
        invitation_type: Keyword.get(attrs, :invitation_type, "member")
      }
      |> Repo.insert()

    id
  end

  defp insert_invitation_with_profile(attrs) do
    auth_user_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    email = Keyword.fetch!(attrs, :email)
    date_of_birth = Keyword.get(attrs, :date_of_birth, ~D[1990-01-01])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "users",
      [
        [
          id: Ecto.UUID.dump!(auth_user_id),
          aud: "authenticated",
          role: "authenticated",
          email: email
        ]
      ],
      prefix: "auth"
    )

    waitlist_id =
      if Keyword.get(attrs, :waitlist, false) do
        id = Ecto.UUID.generate()

        Repo.insert!(%Dhc.Waitlist.WaitlistEntry{
          id: id,
          email: email,
          status: "invited",
          initial_registration_date: now,
          last_status_change: now
        })

        id
      end

    Repo.insert!(%UserProfile{
      id: profile_id,
      supabase_user_id: auth_user_id,
      first_name: "Ada",
      last_name: "Lovelace",
      date_of_birth: date_of_birth,
      phone_number: "+353810000000",
      gender: "woman (cis)",
      pronouns: "she/her",
      is_active: false,
      customer_id: Keyword.get(attrs, :customer_id, "cus_accept"),
      social_media_consent: "no",
      waitlist_id: waitlist_id
    })

    invitation_id =
      insert_invitation(
        email: email,
        status: Keyword.get(attrs, :status, "pending"),
        user_id: auth_user_id,
        waitlist_id: waitlist_id,
        invitation_type: Keyword.get(attrs, :invitation_type, "member")
      )

    %{auth_user_id: auth_user_id, profile_id: profile_id, invitation_id: invitation_id}
  end
end
