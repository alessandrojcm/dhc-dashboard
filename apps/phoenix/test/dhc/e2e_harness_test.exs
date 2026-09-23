defmodule Dhc.E2EHarnessTest do
  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.ClubCalendar
  alias Dhc.Invitations.Invitation
  alias Dhc.Repo

  test "status returns club today and a positive integer schema version" do
    status = E2EHarness.status()

    assert %{today: today, schemaVersion: version} = status
    assert today == Date.to_iso8601(ClubCalendar.today())
    assert is_integer(version)
    assert version > 0

    # Wire shape: MAX(version) is a SQL integer, so JSON must keep a number.
    assert %{"today" => ^today, "schemaVersion" => ^version} =
             status |> Jason.encode!() |> Jason.decode!()
  end

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
