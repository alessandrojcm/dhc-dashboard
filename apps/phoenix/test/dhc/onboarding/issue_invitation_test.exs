defmodule Dhc.Onboarding.IssueInvitationTest do
  @moduledoc """
  ALE-376: `Dhc.Onboarding.issue_invitation/3` is the one synchronous
  single-Invitation issue function. It runs inside the caller's transaction,
  inserts a pending Invitation, queues `inviteMember` and writes the
  processing-log entry, and refuses emails that would collide with an
  existing person.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Onboarding
  alias Dhc.Waitlist.WaitlistEntry

  setup do
    %{admin_id: insert_principal!("issuer-#{System.unique_integer([:positive])}@example.com")}
  end

  test "issues a pending standard Invitation with a 7-day expiry, its email and its log entry",
       %{admin_id: admin_id} do
    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{invitation_id: id, email: "ada@example.com"}} =
             in_transaction(fn ->
               Onboarding.issue_invitation(invite("Ada@Example.com"), admin_id)
             end)

    invitation = Repo.get!(Invitation, id)
    assert invitation.status == "pending"
    assert invitation.pricing_tier == "standard"
    assert invitation.email == "ada@example.com"
    assert invitation.waitlist_id == nil
    assert invitation.created_by_principal_id == admin_id

    expiry_days = DateTime.diff(invitation.expires_at, before, :day)
    assert expiry_days == 7

    assert [%Oban.Job{args: args}] = all_enqueued(worker: Dhc.Email.Worker)
    assert args["transactional_id"] == "inviteMember"
    assert args["email"] == "ada@example.com"
    assert args["data_variables"]["INVITATION_LINK"] =~ "/members/signup/#{id}"

    assert [%ProcessingLog{total_count: 1, success_count: 1, failure_count: 0} = log] =
             Repo.all(from(l in ProcessingLog, where: l.principal_id == ^admin_id))

    assert [%{"email" => "ada@example.com", "success" => true, "invitationId" => ^id}] =
             log.results["items"]
  end

  test "carries the Waitlist entry it was issued for", %{admin_id: admin_id} do
    entry = insert_waitlist_entry!("attended@example.com", "attended")

    assert {:ok, %{invitation_id: id}} =
             in_transaction(fn ->
               Onboarding.issue_invitation(invite("attended@example.com"), admin_id,
                 waitlist_id: entry.id
               )
             end)

    assert %Invitation{waitlist_id: waitlist_id} = Repo.get!(Invitation, id)
    assert waitlist_id == entry.id
    # The standing belongs to the caller; issuing does not change it.
    assert Repo.get!(WaitlistEntry, entry.id).status == "attended"
  end

  test "commits or rolls back with the caller's transaction", %{admin_id: admin_id} do
    assert {:error, :caller_failed} =
             Repo.transaction(fn ->
               {:ok, _} = Onboarding.issue_invitation(invite("rollback@example.com"), admin_id)
               Repo.rollback(:caller_failed)
             end)

    refute Repo.get_by(Invitation, email: "rollback@example.com")
    assert [] = all_enqueued(worker: Dhc.Email.Worker)
    refute Repo.exists?(from(l in ProcessingLog, where: l.principal_id == ^admin_id))
  end

  test "refuses to run outside a transaction", %{admin_id: admin_id} do
    assert_raise ArgumentError, fn ->
      Onboarding.issue_invitation(invite("outside@example.com"), admin_id)
    end
  end

  describe "refusals" do
    test "a pending Invitation for the email", %{admin_id: admin_id} do
      assert {:ok, _} = issue(invite("pending@example.com"), admin_id)

      assert {:error, :duplicate_pending_invitation} =
               issue(invite("Pending@example.com"), admin_id)
    end

    test "an email that belongs to a Principal", %{admin_id: admin_id} do
      insert_principal!("member@example.com")

      assert {:error, :email_is_principal} = issue(invite("Member@example.com"), admin_id)
    end

    for standing <- Dhc.Waitlist.Standing.statuses() do
      @standing standing
      test "an email on the Waitlist as #{standing}", %{admin_id: admin_id} do
        insert_waitlist_entry!("queued@example.com", @standing)

        assert {:error, :email_on_waitlist} = issue(invite("queued@example.com"), admin_id)
      end
    end

    test "an email on another Waitlist entry than the one invited", %{admin_id: admin_id} do
      insert_waitlist_entry!("taken@example.com", "waiting")
      other = insert_waitlist_entry!("other@example.com", "attended")

      assert {:error, :email_on_waitlist} =
               issue(invite("taken@example.com"), admin_id, waitlist_id: other.id)
    end

    test "missing fields and unknown tiers", %{admin_id: admin_id} do
      assert {:error, {:invalid_invite, ["phoneNumber"]}} =
               issue(Map.delete(invite("a@example.com"), "phoneNumber"), admin_id)

      assert {:error, {:invalid_invite, ["dateOfBirth"]}} =
               issue(Map.put(invite("a@example.com"), "dateOfBirth", "not-a-date"), admin_id)

      assert {:error, {:invalid_invite, ["pricingTier"]}} =
               issue(Map.put(invite("a@example.com"), "pricingTier", "gold"), admin_id)
    end

    test "write nothing", %{admin_id: admin_id} do
      insert_principal!("refused@example.com")

      assert {:error, :email_is_principal} = issue(invite("refused@example.com"), admin_id)

      refute Repo.get_by(Invitation, email: "refused@example.com")
      assert [] = all_enqueued(worker: Dhc.Email.Worker)
      refute Repo.exists?(from(l in ProcessingLog, where: l.principal_id == ^admin_id))
    end
  end

  test "record_refused_invitation/3 writes a failed processing-log entry", %{admin_id: admin_id} do
    assert :ok =
             Onboarding.record_refused_invitation("x@example.com", :email_on_waitlist, admin_id)

    assert [%ProcessingLog{total_count: 1, success_count: 0, failure_count: 1} = log] =
             Repo.all(from(l in ProcessingLog, where: l.principal_id == ^admin_id))

    assert [%{"email" => "x@example.com", "success" => false, "error" => ":email_on_waitlist"}] =
             log.results["items"]
  end

  defp issue(invite, admin_id, opts \\ []) do
    Repo.transaction(fn ->
      case Onboarding.issue_invitation(invite, admin_id, opts) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp in_transaction(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end

  defp invite(email) do
    %{
      "firstName" => "Ada",
      "lastName" => "Lovelace",
      "email" => email,
      "phoneNumber" => "+353810000001",
      "dateOfBirth" => "1990-01-01"
    }
  end

  defp insert_principal!(email) do
    id = Ecto.UUID.generate()
    {:ok, _principal} = Dhc.Auth.register_principal_with_id(id, %{email: email})
    id
  end

  defp insert_waitlist_entry!(email, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%WaitlistEntry{
      email: email,
      status: status,
      removed_at: if(status == "removed", do: now),
      initial_registration_date: now,
      last_status_change: now
    })
  end
end
