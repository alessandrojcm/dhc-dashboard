defmodule Dhc.Invitations.ValidityTest do
  use Dhc.DataCase, async: false

  alias Dhc.AuthFixtures
  alias Dhc.Invitations
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Validity
  alias Dhc.Onboarding

  describe "days/0" do
    test "defaults to seven days" do
      assert Validity.days() == 7
    end

    test "honours the configured window" do
      put_validity_days(14)
      assert Validity.days() == 14
    end

    test "falls back to the default for a window that is not a positive number of days" do
      put_validity_days(0)
      assert Validity.days() == 7

      put_validity_days("14")
      assert Validity.days() == 7
    end
  end

  describe "expires_at/1" do
    test "adds the validity window to the given instant" do
      assert Validity.expires_at(~U[2026-11-10 09:00:00Z]) == ~U[2026-11-17 09:00:00Z]
    end

    test "follows the configured window" do
      put_validity_days(14)
      assert Validity.expires_at(~U[2026-11-10 09:00:00Z]) == ~U[2026-11-24 09:00:00Z]
    end
  end

  describe "the Invitation rows" do
    test "a newly issued invitation is valid for the default window" do
      {invitation, _admin} = issue_invitation()

      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :hour) in 167..169
    end

    test "a resent invitation is re-armed with the same window" do
      {invitation, admin} = issue_invitation()

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [status: "expired"]
      )

      before = DateTime.utc_now()

      assert {:ok, %{succeeded: 1, failed: 0}} =
               Invitations.resend_invitation_emails([invitation.email], admin.id)

      rearmed = Repo.get!(Invitation, invitation.id)
      assert rearmed.status == "pending"
      assert DateTime.diff(rearmed.expires_at, before, :hour) in 167..169
    end
  end

  defp put_validity_days(days) do
    Application.put_env(:dhc, :invitation_validity_days, days)
    on_exit(fn -> Application.put_env(:dhc, :invitation_validity_days, 7) end)
  end

  defp issue_invitation do
    admin = AuthFixtures.principal_fixture()
    email = "validity-#{System.unique_integer([:positive])}@example.com"

    invite = %{
      "firstName" => "Ada",
      "lastName" => "Lovelace",
      "email" => email,
      "phoneNumber" => "+353871234567",
      "dateOfBirth" => "1990-01-01"
    }

    {:ok, %{invitation_id: invitation_id}} =
      Repo.transaction(fn ->
        case Onboarding.issue_invitation(invite, admin.id) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    {Repo.get!(Invitation, invitation_id), admin}
  end
end
