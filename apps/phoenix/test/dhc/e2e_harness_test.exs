defmodule Dhc.E2EHarnessTest do
  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Invitations.Invitation
  alias Dhc.Repo

  test "deleting a member fixture detaches Invitations created by its Principal" do
    member =
      E2EHarness.seed("member", %{
        "email" => "fixture-owner-#{System.unique_integer([:positive])}@example.com",
        "roles" => ["committee_coordinator"]
      })

    invitation =
      Repo.insert!(%Invitation{
        email: "fixture-invite-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: Ecto.UUID.generate(),
        status: "pending",
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
        created_by_principal_id: member.userId,
        invitation_type: "member",
        first_name: "Test",
        last_name: "Invitee",
        phone_number: "+353810000001",
        date_of_birth: ~D[1990-01-01]
      })

    assert :ok = E2EHarness.delete_fixture("member", member.userId)
    assert %{created_by_principal_id: nil} = Repo.get!(Invitation, invitation.id)
    refute Repo.get(Principal, member.userId)
  end
end
