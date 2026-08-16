defmodule Dhc.Onboarding.InvitationAcceptanceAttemptsTest do
  use Dhc.DataCase, async: true

  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceAttempts
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim

  test "purge_for_invitation deletes active Discord subject claims before their continuation" do
    invitation =
      %Invitation{
        email: "purge-acceptance-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: Ecto.UUID.generate(),
        status: "pending",
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
        invitation_type: "member",
        first_name: "Ada",
        last_name: "Lovelace",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01]
      }
      |> Repo.insert!()

    attempt =
      %InvitationAcceptanceAttempt{
        invitation_id: invitation.id,
        acceptance_data: %{}
      }
      |> Repo.insert!()

    continuation =
      %InvitationAcceptanceDiscordContinuation{
        invitation_id: invitation.id,
        attempt_id: attempt.id,
        status: "verified",
        expires_at: DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.truncate(:second),
        provider_subject: "purge-subject-#{System.unique_integer([:positive])}",
        subject_fingerprint: "purge-fingerprint"
      }
      |> Repo.insert!()

    %InvitationAcceptanceDiscordSubjectClaim{
      continuation_id: continuation.id,
      provider: "discord",
      provider_subject: continuation.provider_subject
    }
    |> Repo.insert!()

    assert InvitationAcceptanceAttempts.purge_for_invitation(invitation.id) == 1
    refute Repo.get_by(InvitationAcceptanceDiscordSubjectClaim, continuation_id: continuation.id)
    refute Repo.get(InvitationAcceptanceDiscordContinuation, continuation.id)
    refute Repo.get(InvitationAcceptanceAttempt, attempt.id)
  end
end
