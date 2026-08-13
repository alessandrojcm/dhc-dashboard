defmodule DhcWeb.OnboardingControllerTest do
  use DhcWeb.ConnCase, async: true

  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  test "starts and refreshes the safe awaiting-Discord state without conversion", %{conn: conn} do
    invitation = invitation_fixture()

    conn =
      post(conn, "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{
             "data" => %{
               "state" => "awaitingDiscord",
               "continuationId" => continuation_id
             }
           } =
             json_response(conn, 200)

    refreshed =
      conn()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> get("/api/onboarding/acceptance")

    assert %{"data" => %{"state" => "awaitingDiscord"}} = json_response(refreshed, 200)

    duplicate_without_proof =
      post(conn(), "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{"data" => %{"state" => "restartVerification"}} =
             json_response(duplicate_without_proof, 422)

    resumed =
      conn()
      |> put_req_header("x-onboarding-continuation", continuation_id)
      |> post("/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => invitation.email,
        "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
      })

    assert %{"data" => %{"continuationId" => ^continuation_id}} = json_response(resumed, 200)
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

  test "returns restart verification for invalid credentials and missing browser proof", %{
    conn: conn
  } do
    invitation = invitation_fixture()

    invalid =
      post(conn, "/api/onboarding/acceptance", %{
        "invitationId" => invitation.id,
        "email" => "wrong@example.com",
        "dateOfBirth" => "1990-01-01"
      })

    assert %{"data" => %{"state" => "restartVerification"}} = json_response(invalid, 422)

    assert %{"data" => %{"state" => "restartVerification"}} =
             get(conn(), "/api/onboarding/acceptance") |> json_response(422)

    malformed_start =
      post(conn(), "/api/onboarding/acceptance", %{
        "invitationId" => "not-an-id",
        "email" => invitation.email,
        "dateOfBirth" => "1990-01-01"
      })

    assert %{"data" => %{"state" => "restartVerification"}} =
             json_response(malformed_start, 422)

    malformed_proof =
      conn()
      |> put_req_header("x-onboarding-continuation", "not-an-id")
      |> get("/api/onboarding/acceptance")

    assert %{"data" => %{"state" => "restartVerification"}} =
             json_response(malformed_proof, 422)
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
        post(conn, "/api/onboarding/acceptance", %{
          "invitationId" => invitation.id,
          "email" => invitation.email,
          "dateOfBirth" => Date.to_iso8601(invitation.date_of_birth)
        })

      assert %{"data" => %{"state" => "restartVerification"}} = json_response(response, 422)
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
