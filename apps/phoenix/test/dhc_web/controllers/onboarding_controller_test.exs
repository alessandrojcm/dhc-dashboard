defmodule DhcWeb.OnboardingControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Invitations.Invitation
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  setup do
    original_adapter = Application.get_env(:dhc, :onboarding_stripe_adapter)
    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.OnboardingTestStripeAdapter)
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn ->
      Application.put_env(:dhc, :onboarding_stripe_adapter, original_adapter)
      Application.delete_env(:dhc, :onboarding_test_pid)
    end)
  end

  test "starts and refreshes the safe awaiting-OAuth state through a signed cookie", %{conn: conn} do
    invitation = invitation_fixture()

    conn =
      post(conn, "/api/onboarding/invitation-acceptance/verify", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{
             "data" => %{
               "state" => "awaiting_oauth"
             }
           } =
             json_response(conn, 200)

    refute Map.has_key?(json_response(conn, 200)["data"], "continuationId")

    assert %{http_only: true, same_site: "Lax", secure: false, value: _continuation_id} =
             conn.resp_cookies["_dhc_onboarding_acceptance"]

    refreshed =
      conn
      |> recycle()
      |> get("/api/onboarding/invitation-acceptance")

    assert %{"data" => %{"state" => "awaiting_oauth"}} = json_response(refreshed, 200)

    duplicate_without_proof =
      post(conn(), "/api/onboarding/invitation-acceptance/verify", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{"data" => %{"state" => "restart_verification"}} =
             json_response(duplicate_without_proof, 409)

    resumed =
      conn
      |> recycle()
      |> post("/api/onboarding/invitation-acceptance/verify", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{"data" => %{"state" => "awaiting_oauth"}} = json_response(resumed, 200)
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1

    assert %InvitationAcceptanceAttempt{
             stripe_customer_id: nil,
             stripe_state: %{},
             acceptance_data: %{}
           } = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert Repo.aggregate(InvitationAcceptanceDiscordContinuation, :count) == 1
    refute Repo.get(Dhc.Auth.Principal, invitation.prospective_principal_id)
    refute Repo.exists?(Dhc.Auth.ExternalIdentity)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
    refute Repo.exists?(Dhc.Auth.UserRole)
    refute Repo.exists?(UserProfile)
    refute Repo.exists?(MemberProfile)
    refute Repo.exists?("oban_jobs")
  end

  test "verifies only the Discord subject, creates a transient claim, and returns a safe resume state",
       %{conn: conn} do
    invitation = invitation_fixture()

    started =
      post(conn, "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    [continuation_id] = get_resp_header(started, "x-onboarding-continuation")

    oauth =
      started
      |> recycle()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> get("/api/onboarding/acceptance/discord")

    oauth_redirect = oauth |> redirected_to(302) |> URI.parse()

    assert %URI{
             scheme: "https",
             host: "discord.example.com",
             path: "/oauth2/authorize"
           } = oauth_redirect

    assert URI.decode_query(oauth_redirect.query) == %{
             "redirect_uri" => "http://localhost:5173/auth/discord/acceptance/callback",
             "state" => "test-state"
           }

    assert get_session(oauth, :discord_oauth_flow).purpose ==
             {:invitation_acceptance, continuation_id}

    callback =
      oauth
      |> recycle()
      |> get("/api/auth/discord/callback?state=test-state&code=success")

    assert redirected_to(callback, 302) ==
             "http://localhost:5173/members/signup/#{invitation.id}/resume"

    refute callback.resp_cookies["_dhc_session"]
    refute Repo.exists?(Dhc.Auth.ExternalIdentity)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)

    assert %InvitationAcceptanceDiscordSubjectClaim{provider: "discord"} =
             Repo.one(InvitationAcceptanceDiscordSubjectClaim)

    safe =
      callback
      |> recycle()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> get("/api/onboarding/acceptance")

    invitation_email = invitation.email

    assert %{
             "data" => %{
               "state" => "discordVerified",
               "invitationEmail" => ^invitation_email,
               "discord" => %{
                 "username" => "request-member",
                 "avatarUrl" => "https://cdn.discord.example.com/avatars/request-member.png"
               }
             }
           } = json_response(safe, 200)

    refute Map.has_key?(json_response(safe, 200)["data"], "continuationId")

    replay =
      callback
      |> recycle()
      |> get("/api/auth/discord/callback?state=test-state&code=success")

    assert redirected_to(replay, 302) == "http://localhost:5173/auth?discord=failed"
    assert Repo.aggregate(InvitationAcceptanceDiscordSubjectClaim, :count) == 1
    refute Repo.exists?(ExternalIdentity)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
  end

  test "cancelling a verified continuation zeroizes it and releases its subject claim", %{
    conn: conn
  } do
    invitation = invitation_fixture()

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _} =
      Dhc.Onboarding.verify_discord(state.continuation_id, %{
        "sub" => "cancel-subject",
        "preferred_username" => "cancelled"
      })

    response =
      conn
      |> put_req_header("x-onboarding-continuation", state.continuation_id)
      |> post("/api/onboarding/acceptance/discord/cancel")

    assert %{"data" => %{"state" => "restartVerification"}} = json_response(response, 200)
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, state.continuation_id)
    assert continuation.status == "cancelled"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    assert is_binary(continuation.subject_fingerprint)
  end

  test "Continue finalizes the Elements ConfirmationToken on the server without a Session", %{
    conn: conn
  } do
    invitation = invitation_fixture()

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _verified} =
      Dhc.Onboarding.verify_discord(state.continuation_id, %{
        "sub" => "controller-paid-subject",
        "preferred_username" => "controller-member"
      })

    continued =
      conn
      |> put_req_header("x-onboarding-continuation", state.continuation_id)
      |> post("/api/onboarding/acceptance/continue", %{
        "nextOfKinName" => "Grace Hopper",
        "nextOfKinPhone" => "+353810000099",
        "stripeConfirmationToken" => "ctok_controller_paid",
        "mandateContext" => %{
          "ipAddress" => "127.0.0.1",
          "userAgent" => "controller-test"
        }
      })

    assert %{"data" => %{"state" => "accepted"}} = json_response(continued, 200)

    refute Map.has_key?(json_response(continued, 200)["data"], "attemptId")
    assert_received {:provision_membership, %{confirmation_token: "ctok_controller_paid"}}
    refute continued.resp_cookies["_dhc_session"]
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
    assert Repo.exists?(ExternalIdentity)
  end

  test "an existing External Identity produces the same neutral collision state without Stripe or Session work",
       %{
         conn: conn
       } do
    invitation = invitation_fixture()

    principal =
      %Principal{email: "existing-discord-owner@example.com"}
      |> Repo.insert!()

    %ExternalIdentity{
      principal_id: principal.id,
      provider: "discord",
      provider_subject: "discord-request-success",
      metadata: %{}
    }
    |> Repo.insert!()

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:error, :collision} =
             Dhc.Onboarding.verify_discord(state.continuation_id, %{
               "sub" => "discord-request-success",
               "preferred_username" => "must-not-identify-owner"
             })

    response =
      conn
      |> put_req_header("x-onboarding-continuation", state.continuation_id)
      |> get("/api/onboarding/acceptance")

    assert %{"data" => %{"state" => "discordCollision"}} = json_response(response, 200)

    continuation =
      Repo.get!(InvitationAcceptanceDiscordContinuation, state.continuation_id)

    assert continuation.status == "collision"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    assert is_binary(continuation.subject_fingerprint)
    assert Repo.get!(InvitationAcceptanceAttempt, continuation.attempt_id).status == "declined"
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
    refute Repo.exists?("oban_jobs")
  end

  test "a retired External Identity does not block a fresh subject claim" do
    invitation = invitation_fixture()

    principal =
      %Principal{email: "retired-discord-owner@example.com"}
      |> Repo.insert!()

    %ExternalIdentity{
      principal_id: principal.id,
      provider: "discord",
      provider_subject: "retired-discord-subject",
      metadata: %{},
      sign_in_disabled_at: DateTime.utc_now(),
      retired_at: DateTime.utc_now()
    }
    |> Repo.insert!()

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:ok, %{state: "discordVerified"}} =
             Dhc.Onboarding.verify_discord(state.continuation_id, %{
               "sub" => "retired-discord-subject"
             })

    assert Repo.get_by!(InvitationAcceptanceDiscordSubjectClaim,
             continuation_id: state.continuation_id
           ).provider_subject == "retired-discord-subject"

    refute Repo.exists?(Dhc.Auth.PrincipalToken)
  end

  test "the Postgres subject-claim constraint prevents a second acceptance from reserving one Discord subject" do
    first = invitation_fixture()
    second = invitation_fixture()

    {:ok, first_state} =
      Dhc.Onboarding.start_acceptance(
        first.id,
        first.email,
        Date.to_iso8601(first.date_of_birth)
      )

    {:ok, second_state} =
      Dhc.Onboarding.start_acceptance(
        second.id,
        second.email,
        Date.to_iso8601(second.date_of_birth)
      )

    claims = %{"sub" => "one-subject", "preferred_username" => "same-account"}

    assert {:ok, %{state: "discordVerified"}} =
             Dhc.Onboarding.verify_discord(first_state.continuation_id, claims)

    assert {:error, :collision} =
             Dhc.Onboarding.verify_discord(second_state.continuation_id, claims)

    assert Repo.aggregate(InvitationAcceptanceDiscordSubjectClaim, :count) == 1

    assert Repo.get!(
             InvitationAcceptanceDiscordContinuation,
             first_state.continuation_id
           ).status == "verified"

    second_continuation =
      Repo.get!(InvitationAcceptanceDiscordContinuation, second_state.continuation_id)

    assert second_continuation.status == "collision"
    assert second_continuation.provider_subject == nil
  end

  test "an OAuth protocol failure terminalizes the continuation without creating credentials", %{
    conn: conn
  } do
    invitation = invitation_fixture()

    started =
      post(conn, "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    [continuation_id] = get_resp_header(started, "x-onboarding-continuation")

    callback =
      started
      |> recycle()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> get("/api/onboarding/acceptance/discord")
      |> recycle()
      |> get("/api/auth/discord/callback?state=wrong&code=success")

    assert redirected_to(callback, 302) ==
             "http://localhost:5173/members/signup/#{invitation.id}/resume"

    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, continuation_id)
    assert continuation.status == "failed"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    refute Repo.exists?(ExternalIdentity)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
  end

  test "provider cancellation has the same credential-free local resume outcome", %{conn: conn} do
    invitation = invitation_fixture()

    started =
      post(conn, "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    [continuation_id] = get_resp_header(started, "x-onboarding-continuation")

    callback =
      started
      |> recycle()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> get("/api/onboarding/acceptance/discord")
      |> recycle()
      |> get("/api/auth/discord/callback?error=access_denied&state=test-state")

    assert redirected_to(callback, 302) ==
             "http://localhost:5173/members/signup/#{invitation.id}/resume"

    assert Repo.get!(
             InvitationAcceptanceDiscordContinuation,
             continuation_id
           ).status == "cancelled"

    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    refute Repo.exists?(ExternalIdentity)
    refute Repo.exists?(Dhc.Auth.PrincipalToken)
  end

  test "reading an expired verified continuation zeroizes raw Discord data and releases its claim",
       %{
         conn: conn
       } do
    invitation = invitation_fixture()

    {:ok, state} =
      Dhc.Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _safe_state} =
      Dhc.Onboarding.verify_discord(state.continuation_id, %{
        "sub" => "expiring-subject",
        "preferred_username" => "must-be-zeroized"
      })

    InvitationAcceptanceDiscordContinuation
    |> Repo.get!(state.continuation_id)
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    response =
      conn
      |> put_req_header("x-onboarding-continuation", state.continuation_id)
      |> get("/api/onboarding/acceptance")

    assert %{"data" => %{"state" => "restartVerification"}} =
             json_response(response, 422)

    continuation =
      Repo.get!(InvitationAcceptanceDiscordContinuation, state.continuation_id)

    assert continuation.status == "expired"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    assert is_binary(continuation.subject_fingerprint)
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
  end

  test "returns restart verification for invalid credentials and missing browser proof", %{
    conn: conn
  } do
    invitation = invitation_fixture()

    invalid =
      post(conn, "/api/onboarding/invitation-acceptance/verify", %{
        "invitationId" => invitation.id,
        "email" => "wrong@example.com",
        "dateOfBirth" => "1990-01-01"
      })

    assert %{"data" => %{"state" => "restart_verification"}} = json_response(invalid, 422)

    assert %{"data" => %{"state" => "restart_verification"}} =
             get(conn(), "/api/onboarding/invitation-acceptance") |> json_response(409)

    malformed_start =
      post(conn(), "/api/onboarding/invitation-acceptance/verify", %{
        "invitationId" => "not-an-id",
        "email" => invitation.email,
        "dateOfBirth" => "1990-01-01"
      })

    assert %{"data" => %{"state" => "restart_verification"}} =
             json_response(malformed_start, 422)

    malformed_proof =
      conn()
      |> put_req_cookie("_dhc_onboarding_acceptance", "not-a-signed-cookie")
      |> get("/api/onboarding/invitation-acceptance")

    assert %{"data" => %{"state" => "restart_verification"}} =
             json_response(malformed_proof, 409)
  end

  test "expired, replay-ineligible, and converted Invitations return the same safe state", %{
    conn: conn
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invitations = [
      invitation_fixture(%{expires_at: DateTime.add(now, -1, :second)}),
      invitation_fixture(%{status: "revoked"}),
      invitation_fixture(%{status: "accepted"})
    ]

    for invitation <- invitations do
      response =
        post(conn, "/api/onboarding/invitation-acceptance/verify", %{
          "invitationId" => invitation.id,
          "email" => invitation.email,
          "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
        })

      assert %{"data" => %{"state" => "restart_verification"}} = json_response(response, 422)
    end

    refute Repo.exists?(InvitationAcceptanceAttempt)
    refute Repo.exists?(InvitationAcceptanceDiscordContinuation)
  end

  defp invitation_fixture(attrs \\ %{}) do
    base = %{
      email: "onboarding-#{System.unique_integer([:positive])}@example.com",
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
      invitation_type: "member",
      first_name: "Ada",
      last_name: "Lovelace",
      phone_number: "+353810000000",
      date_of_birth: ~D[1990-01-01]
    }

    base
    |> Map.merge(attrs)
    |> then(&struct!(Invitation, &1))
    |> Repo.insert!()
  end
end
