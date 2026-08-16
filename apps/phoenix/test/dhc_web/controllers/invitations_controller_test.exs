defmodule DhcWeb.InvitationsControllerTest do
  use DhcWeb.ConnCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.Auth.Principal
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

  setup do
    original = %{
      auth_verifier: Application.get_env(:dhc, :auth_verifier),
      onboarding_stripe_adapter: Application.get_env(:dhc, :onboarding_stripe_adapter),
      onboarding_stripe_customer_result:
        Application.get_env(:dhc, :onboarding_stripe_customer_result),
      onboarding_stripe_result: Application.get_env(:dhc, :onboarding_stripe_result),
      onboarding_test_pid: Application.get_env(:dhc, :onboarding_test_pid)
    }

    Application.put_env(:dhc, :auth_verifier, Verifier)
    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Test)
    Application.put_env(:dhc, :onboarding_stripe_customer_result, {:ok, "cus_accept"})
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn ->
      Enum.each(original, fn
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

    test "POST /api/invitations/:id/accept rejects a legacy token before Stripe", %{conn: conn} do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "legacy-token@example.com", waitlist: true)

      {:ok, token} =
        Dhc.Invitations.issue_verification_token(
          invitation_id,
          "legacy-token@example.com",
          ~D[1990-01-01]
        )

      conn =
        post(conn, "/api/invitations/#{invitation_id}/accept", %{
          "verificationToken" => token,
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_must_not_be_used"
        })

      assert %{
               "errors" => %{"detail" => "Discord verification is required before payment"}
             } = json_response(conn, 409)

      refute_receive {:create_customer, _}
      refute_receive {:provision_membership, _}
      refute Repo.exists?(Dhc.Onboarding.InvitationAcceptanceAttempt)
    end

    test "POST /api/invitations/:id/accept atomically creates member state", %{conn: conn} do
      %{invitation_id: invitation_id, user_id: user_id} =
        insert_invitation_with_profile(email: "accept@example.com", waitlist: true)

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"data" => %{"accepted" => true, "memberId" => ^user_id}} = json_response(conn, 200)

      # The customer_id pre-attached by insert_invitation_with_profile/1 is
      # the one acceptance passes to the payment processor (no
      # create_customer call when stripe_customer_id is already set).
      refute_receive {:create_customer, _}

      assert_receive {:provision_membership,
                      %{
                        customer_id: "cus_accept",
                        confirmation_token: "ctok_test",
                        coupon_code: nil,
                        invitation_id: ^invitation_id
                      }}

      assert Repo.get!(Invitation, invitation_id).status == "accepted"

      # ALE-162: acceptance creates the pre-allocated prospective Principal.
      assert %Principal{id: ^user_id, email: "accept@example.com"} =
               Repo.get!(Principal, user_id)

      # Acceptance creates the UserProfile (no pre-existing profile to flip).
      user_profile = Repo.get_by!(UserProfile, principal_id: user_id)
      assert user_profile.first_name == "Ada"
      assert user_profile.last_name == "Lovelace"
      assert user_profile.date_of_birth == ~D[1990-01-01]
      assert user_profile.customer_id == "cus_accept"
      assert user_profile.is_active == true

      member = Repo.get!(MemberProfile, user_id)
      assert member.user_profile_id == user_profile.id
      assert member.next_of_kin_name == "Ada Lovelace"
      assert member.insurance_form_submitted == true

      assert Repo.exists?(
               from r in Dhc.Auth.UserRole,
                 where: r.principal_id == ^user_id and r.role == "member"
             )

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "accept@example.com",
                 select: w.status
             ) == "joined"

      # ALE-162 / ADR 0010: acceptance must not establish a session or send a
      # magic link. The auth session is created later via the normal sign-in
      # path. Assert no session tokens and no magic-link email jobs were
      # produced as a side effect of acceptance.
      assert Repo.aggregate(
               from(t in Dhc.Auth.PrincipalToken, where: t.context == "session"),
               :count
             ) == 0

      assert Repo.aggregate(
               from(t in Dhc.Auth.PrincipalToken, where: t.context == "login"),
               :count
             ) == 0

      # No magic-link email was enqueued (only invite-member emails, if any).
      refute_enqueued(worker: Dhc.Email.Worker)
    end

    test "POST /api/invitations/:id/accept creates a Stripe customer when none is attached",
         %{conn: conn} do
      %{invitation_id: invitation_id, user_id: user_id} =
        insert_invitation_with_profile(email: "no-customer@example.com", waitlist: true)

      # Strip the pre-attached customer so acceptance has to create one.
      Repo.update_all(
        from(i in Invitation, where: i.id == ^invitation_id),
        set: [stripe_customer_id: nil]
      )

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"data" => %{"accepted" => true, "memberId" => ^user_id}} = json_response(conn, 200)

      assert_receive {:create_customer, %{email: "no-customer@example.com"}}
      assert_receive {:provision_membership, %{customer_id: "cus_accept"}}

      assert Repo.get!(Invitation, invitation_id).status == "accepted"
    end

    test "POST /api/invitations/:id/accept rolls back when Stripe payment fails", %{conn: conn} do
      %{invitation_id: invitation_id, user_id: user_id} =
        insert_invitation_with_profile(email: "stripe-fail@example.com", waitlist: true)

      Application.put_env(:dhc, :onboarding_stripe_result, {:error, :card_declined})

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_must_not_be_used"
        })

      assert %{"errors" => %{"detail" => "Payment could not be completed"}} =
               json_response(conn, 402)

      assert_receive {:provision_membership, %{confirmation_token: "ctok_must_not_be_used"}}
      assert_receive {:cancel_membership, _stripe_state}

      assert Repo.get!(Invitation, invitation_id).status == "pending"

      # ALE-162: failed acceptance leaves no partial record set. No
      # Principal, no UserProfile, no MemberProfile, no role, and the
      # waitlist entry stays `invited` (not `joined`).
      refute Repo.get(Principal, user_id)
      refute Repo.exists?(from up in UserProfile, where: up.principal_id == ^user_id)
      refute Repo.exists?(from m in MemberProfile, where: m.id == ^user_id)

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "stripe-fail@example.com",
                 select: w.status
             ) == "invited"
    end

    test "POST /api/invitations/:id/accept rejects blank required fields before mutating", %{
      conn: conn
    } do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "blank-accept@example.com", waitlist: true)

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "  ",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"errors" => %{"detail" => "acceptance payload is invalid"}} =
               json_response(conn, 400)

      assert Repo.get!(Invitation, invitation_id).status == "pending"

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "blank-accept@example.com",
                 select: w.status
             ) == "invited"

      refute_receive {:provision_membership, _attrs}
    end

    test "POST /api/invitations/:id/accept rolls back when member creation fails", %{
      conn: conn
    } do
      %{invitation_id: invitation_id, user_id: user_id} =
        insert_invitation_with_profile(email: "rollback@example.com", waitlist: true)

      continuation_id = verified_continuation_for(invitation_id)

      # Pre-existing Principal/Member records for the prospective Principal id —
      # acceptance must detect this and roll back as :invalid_invitation
      # (replay defense / belt-and-braces check per ADR 0010).
      Repo.insert!(%Principal{id: user_id, email: "existing-#{user_id}@example.com"})

      existing_profile =
        Repo.insert!(%UserProfile{
          id: Ecto.UUID.generate(),
          principal_id: user_id,
          first_name: "Existing",
          last_name: "Member",
          phone_number: "+353810000000",
          date_of_birth: ~D[1990-01-01],
          is_active: false,
          social_media_consent: "no"
        })

      Repo.insert!(%MemberProfile{
        id: user_id,
        user_profile_id: existing_profile.id,
        next_of_kin_name: "Existing Member",
        next_of_kin_phone: "+353 1 999 9999",
        preferred_weapon: [],
        membership_start_date: DateTime.utc_now() |> DateTime.truncate(:second),
        insurance_form_submitted: true,
        additional_data: %{}
      })

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"errors" => %{"detail" => "Invitation cannot be accepted"}} =
               json_response(conn, 422)

      assert Repo.get!(Invitation, invitation_id).status == "pending"

      # The pre-existing MemberProfile and UserProfile are untouched
      # (acceptance rolled back before touching them).
      assert Repo.get!(MemberProfile, user_id).next_of_kin_name == "Existing Member"
      assert Repo.get!(UserProfile, existing_profile.id).is_active == false

      assert Repo.one!(
               from w in Dhc.Waitlist.WaitlistEntry,
                 where: w.email == "rollback@example.com",
                 select: w.status
             ) == "invited"

      # The payment processor was never called — the replay check runs
      # before Stripe customer / payment work.
      refute_receive {:provision_membership, _attrs}
    end

    test "POST /api/invitations/:id/accept is idempotent on replay (status flip is the guard)",
         %{conn: conn} do
      %{invitation_id: invitation_id} =
        insert_invitation_with_profile(email: "replay@example.com", waitlist: true)

      continuation_id = verified_continuation_for(invitation_id)

      body = %{
        "nextOfKinName" => "Ada Lovelace",
        "nextOfKinPhone" => "+353 1 000 0000",
        "stripeConfirmationToken" => "ctok_test"
      }

      assert %{"data" => %{"accepted" => true}} =
               conn
               |> put_req_header("x-onboarding-continuation", continuation_id)
               |> post("/api/invitations/#{invitation_id}/accept", body)
               |> json_response(200)

      # A second acceptance with the consumed Continuation finds the
      # invitation no longer pending and rolls back. The invitation-status
      # flip remains the final replay defense.
      assert %{"errors" => %{"detail" => "Invitation cannot be accepted"}} =
               conn
               |> put_req_header("x-onboarding-continuation", continuation_id)
               |> post("/api/invitations/#{invitation_id}/accept", body)
               |> json_response(422)
    end
  end

  describe "invitation acceptance reuses the waitlist UserProfile" do
    # The waitlist intake (`Dhc.Waitlist.create_entry/1`) creates an inactive
    # `user_profiles` row carrying the intake-captured fields (first/last/DOB/
    # gender/pronouns/phone/social_media_consent/medical_conditions) plus an
    # optional guardian row. Pre-ALE-176, acceptance created a *second*
    # `user_profiles` row keyed to the same `waitlist_id`, discarding the
    # intake fields and orphaning the guardian. ALE-176 makes acceptance lock
    # the existing waitlist UserProfile `FOR UPDATE` and reuse it, setting
    # `principal_id`/`is_active`/`customer_id` while preserving the rest.
    #
    # TDD workflow: the "does not create a duplicate" test below is the
    # characterization — it went red against the pre-ALE-176 `accept/5`
    # (which left two `user_profiles` rows per `waitlist_id`) and goes green
    # once the reuse path lands, confirming the duplicate behavior changed.
    # The companion tests assert the desired reuse + guardian preservation.

    test "acceptance does not create a duplicate UserProfile",
         %{conn: conn} do
      %{invitation_id: invitation_id, user_id: user_id, waitlist_id: waitlist_id} =
        insert_invitation_from_waitlist_entry(
          email: "reuse@example.com",
          intake: [
            first_name: "IntakeFirst",
            last_name: "IntakeLast",
            gender: "non-binary",
            pronouns: "they/them",
            phone_number: "+353871234567",
            social_media_consent: "yes_recognizable",
            medical_conditions: "asthma"
          ]
        )

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"data" => %{"accepted" => true, "memberId" => ^user_id}} = json_response(conn, 200)

      # Exactly one UserProfile references the waitlist_id — pre-ALE-176 this
      # was two (the intake row + a duplicate acceptance row). This is the
      # assertion that flipped from red to green when the reuse path landed.
      profiles =
        from(up in UserProfile, where: up.waitlist_id == ^waitlist_id) |> Repo.all()

      assert length(profiles) == 1

      reused = hd(profiles)

      # The reused row is the one acceptance flipped to active + linked to
      # the new Principal, carrying the Stripe customer from the invitation.
      assert reused.principal_id == user_id
      assert reused.is_active == true
      assert reused.customer_id == "cus_accept"

      # Intake-captured fields are preserved (not overwritten with the
      # invitation's default "Ada Lovelace" / "no" shape). All fields the
      # intake captures (first/last/DOB/gender/pronouns/phone/social_media_
      # consent/medical_conditions) are checked.
      assert reused.first_name == "IntakeFirst"
      assert reused.last_name == "IntakeLast"
      assert reused.date_of_birth == ~D[1990-01-01]
      assert reused.gender == "non-binary"
      assert reused.pronouns == "they/them"
      assert reused.phone_number == "+353871234567"
      assert reused.social_media_consent == "yes_recognizable"
      assert reused.medical_conditions == "asthma"

      # The MemberProfile points at the reused UserProfile id (the triangle
      # invariant survives acceptance without a duplicate).
      member = Repo.get!(MemberProfile, user_id)
      assert member.user_profile_id == reused.id
    end

    test "acceptance preserves the guardian row linked to the waitlist UserProfile",
         %{conn: conn} do
      %{invitation_id: invitation_id, waitlist_id: waitlist_id, profile_id: profile_id} =
        insert_invitation_from_waitlist_entry(
          email: "guardian@example.com",
          intake: [guardian: true]
        )

      continuation_id = verified_continuation_for(invitation_id)

      conn =
        conn
        |> put_req_header("x-onboarding-continuation", continuation_id)
        |> post("/api/invitations/#{invitation_id}/accept", %{
          "nextOfKinName" => "Ada Lovelace",
          "nextOfKinPhone" => "+353 1 000 0000",
          "stripeConfirmationToken" => "ctok_test"
        })

      assert %{"data" => %{"accepted" => true}} = json_response(conn, 200)

      # The guardian row survived acceptance and still points at the same
      # UserProfile id (no orphaned guardian pointing at a dropped duplicate).
      guardian =
        Repo.one!(
          from wg in "waitlist_guardians",
            where: wg.profile_id == ^Ecto.UUID.dump!(profile_id),
            select: %{first_name: wg.first_name, last_name: wg.last_name}
        )

      assert guardian.first_name == "Parent"
      assert guardian.last_name == "Guardian"

      # And there is still only one UserProfile for the waitlist_id.
      assert Repo.aggregate(
               from(up in UserProfile, where: up.waitlist_id == ^waitlist_id),
               :count
             ) == 1
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
  # ALE-162 (ADR 0010): issue time is side-effect free — the helper only
  # inserts the invitation row. No `auth.users` row, no `user_profiles` row,
  # no Stripe customer is created at issue time. The invitation carries the
  # invite data (first/last/phone/DOB) and a pre-attached
  # `stripe_customer_id` so acceptance tests can exercise the "reuse
  # attached customer" path without standing up a Stripe Bypass. Tests that
  # want to exercise the "acceptance creates the customer" path strip the
  # customer_id after insert.
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
        date_of_birth: Keyword.get(attrs, :date_of_birth, ~D[1990-01-01]),
        stripe_customer_id: Keyword.get(attrs, :stripe_customer_id, "cus_accept")
      }
      |> Repo.insert()

    id
  end

  defp verified_continuation_for(invitation_id) do
    invitation = Repo.get!(Invitation, invitation_id)

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, %{state: "discordVerified"}} =
      Dhc.Onboarding.verify_discord(state.continuation_id, %{
        "sub" => "controller-subject-#{System.unique_integer([:positive])}",
        "preferred_username" => "controller-member"
      })

    state.continuation_id
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
        date_of_birth: date_of_birth,
        stripe_customer_id: Keyword.get(attrs, :stripe_customer_id, "cus_accept")
      }
      |> Repo.insert()

    %{invitation_id: invitation_id, user_id: user_id, waitlist_id: waitlist_id}
  end

  # ALE-176: builds the pre-acceptance state exactly as `Dhc.Waitlist.create_entry/1`
  # leaves it — a waitlist entry plus an inactive `user_profiles` intake row
  # (carrying first/last/DOB/gender/pronouns/phone/social_media_consent/
  # medical_conditions) and an optional guardian — then mints a pending
  # Invitation tied to that `waitlist_id` (the way bulk invite does). This is
  # the shape acceptance must reuse rather than duplicate.
  defp insert_invitation_from_waitlist_entry(attrs) do
    email = Keyword.fetch!(attrs, :email)
    date_of_birth = Keyword.get(attrs, :date_of_birth, ~D[1990-01-01])
    intake = Keyword.get(attrs, :intake, [])

    waitlist_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    invitation_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _waitlist} =
      %Dhc.Waitlist.WaitlistEntry{
        id: waitlist_id,
        email: email,
        status: "invited",
        initial_registration_date: now,
        last_status_change: now
      }
      |> Repo.insert()

    {:ok, _profile} =
      %UserProfile{
        id: profile_id,
        first_name: Keyword.get(intake, :first_name, "IntakeFirst"),
        last_name: Keyword.get(intake, :last_name, "IntakeLast"),
        is_active: false,
        date_of_birth: date_of_birth,
        gender: Keyword.get(intake, :gender, "man (cis)"),
        pronouns: Keyword.get(intake, :pronouns),
        phone_number: Keyword.get(intake, :phone_number, "+353810000000"),
        social_media_consent: Keyword.get(intake, :social_media_consent, "no"),
        medical_conditions: Keyword.get(intake, :medical_conditions),
        waitlist_id: waitlist_id
      }
      |> Repo.insert()

    if Keyword.get(intake, :guardian, false) do
      {1, _} =
        Repo.insert_all("waitlist_guardians", [
          %{
            id: Ecto.UUID.dump!(Ecto.UUID.generate()),
            profile_id: Ecto.UUID.dump!(profile_id),
            first_name: "Parent",
            last_name: "Guardian",
            phone_number: "+353 1 111 1111",
            created_at: now
          }
        ])
    end

    expires_at = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    {:ok, _invitation} =
      %Invitation{
        id: invitation_id,
        email: email,
        prospective_principal_id: user_id,
        waitlist_id: waitlist_id,
        status: "pending",
        expires_at: expires_at,
        invitation_type: "member",
        first_name: "Ada",
        last_name: "Lovelace",
        phone_number: "+353810000000",
        date_of_birth: date_of_birth,
        stripe_customer_id: "cus_accept"
      }
      |> Repo.insert()

    %{
      invitation_id: invitation_id,
      user_id: user_id,
      waitlist_id: waitlist_id,
      profile_id: profile_id
    }
  end
end
