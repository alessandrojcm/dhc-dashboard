defmodule Dhc.Invitations.BulkInviteWorkerTest do
  use Dhc.DataCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.Repository
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Notifications.Broadcaster
  alias Dhc.Notifications.Notification
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  # ALE-162 (ADR 0010): issue time is side-effect free. The worker no longer
  # calls the Supabase admin API, creates a Stripe customer, or inserts a
  # user_profiles row. Each invite goes through Dhc.Onboarding.issue_invitation/3
  # (ALE-376), which inserts the pending invitation, enqueues the inviteMember
  # email and writes one processing-log entry; refusals are logged too.
  #
  # Acceptance (not the worker) materializes the Principal + UserProfile +
  # MemberProfile + role. Acceptance creates the Stripe customer; pricing is
  # read-only.

  describe "perform/1 validation" do
    test "returns validation errors when invites are missing" do
      assert {:error, {:validation, errors}} =
               BulkInviteWorker.perform(%Oban.Job{
                 args: %{"user" => %{"id" => Ecto.UUID.generate()}}
               })

      assert "missing invites" in errors
    end

    test "returns validation errors when invites are empty" do
      args = %{"invites" => [], "user" => %{"id" => Ecto.UUID.generate()}}

      assert {:error, {:validation, errors}} = BulkInviteWorker.perform(%Oban.Job{args: args})
      assert "invites must be a non-empty list" in errors
    end

    test "returns validation errors when user id is missing" do
      args = %{"invites" => [%{"email" => "member@example.com"}], "user" => %{}}

      assert {:error, {:validation, errors}} = BulkInviteWorker.perform(%Oban.Job{args: args})
      assert "user.id is required" in errors
    end
  end

  describe "perform/1 insurance link" do
    test "omits an unconfigured insurance link so the email template uses its fallback" do
      created_by_id = insert_principal!("insurance-admin@example.com")
      Repo.delete_all(from(s in Dhc.Settings.Setting, where: s.key == "hema_insurance_form_link"))

      args = %{
        "invites" => [base_invite("insurance-invite@example.com")],
        "user" => %{"id" => created_by_id}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})
      assert [%Oban.Job{args: email_args}] = all_enqueued(worker: Dhc.Email.Worker)
      refute Map.has_key?(email_args["data_variables"], "INSURANCE_FORM_LINK")
    end
  end

  describe "perform/1 pricing tiers" do
    test "persists the invited pricing tier on the invitation" do
      created_by_id = insert_principal!("tier-admin@example.com")

      args = %{
        "invites" => [
          base_invite("coach-invite@example.com", %{"pricingTier" => "coach"})
        ],
        "user" => %{"id" => created_by_id, "email" => "tier-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      assert %{pricing_tier: "coach"} =
               Repo.get_by!(Invitation, email: "coach-invite@example.com")
    end

    test "defaults to the standard tier when no pricing tier is supplied" do
      created_by_id = insert_principal!("standard-tier-admin@example.com")

      args = %{
        "invites" => [base_invite("standard-invite@example.com")],
        "user" => %{"id" => created_by_id, "email" => "standard-tier-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      assert %{pricing_tier: "standard"} =
               Repo.get_by!(Invitation, email: "standard-invite@example.com")
    end

    test "records a per-invite failure for an unknown pricing tier" do
      created_by_id = insert_principal!("bad-tier-admin@example.com")

      args = %{
        "invites" => [base_invite("gold-invite@example.com", %{"pricingTier" => "gold"})],
        "user" => %{"id" => created_by_id, "email" => "bad-tier-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      refute Repo.get_by(Invitation, email: "gold-invite@example.com")

      assert [%ProcessingLog{failure_count: 1} = log] = logs_for(created_by_id)

      assert [%{"success" => false, "error" => error}] = log.results["items"]
      assert error =~ "invalid_invite"
      assert [] = all_enqueued(worker: Dhc.Email.Worker)
    end
  end

  describe "perform/1 direct-invitation refusals" do
    test "issues a direct invite with no profile or Stripe customer, logging it" do
      created_by_id = insert_principal!("admin@example.com")
      insurance_link = "https://insurance.example.com/onboarding.html"
      assert {:ok, _} = Dhc.Settings.update("hema_insurance_form_link", insurance_link)

      args = %{
        "invites" => [base_invite("Ada@Example.com")],
        "user" => %{"id" => created_by_id, "email" => "admin@example.com"}
      }

      # The bulk invitation workflow must produce exactly one
      # notification_created signal for the admin.
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(created_by_id))

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      assert %Invitation{} = invitation = Repo.get_by(Invitation, email: "ada@example.com")
      assert invitation.status == "pending"
      assert invitation.waitlist_id == nil
      assert invitation.created_by_principal_id == created_by_id
      assert invitation.date_of_birth == ~D[1990-01-01]
      assert invitation.first_name == "Ada"
      assert invitation.prospective_principal_id != nil

      refute Repo.exists?(
               from up in UserProfile,
                 where: up.principal_id == ^invitation.prospective_principal_id
             )

      assert [%Oban.Job{args: email_args}] = all_enqueued(worker: Dhc.Email.Worker)
      assert email_args["email"] == "ada@example.com"
      assert email_args["transactional_id"] == "inviteMember"
      assert email_args["data_variables"]["INSURANCE_FORM_LINK"] == insurance_link

      assert email_args["data_variables"]["INVITATION_LINK"] =~
               "/members/signup/#{invitation.id}"

      assert [%ProcessingLog{total_count: 1, success_count: 1, failure_count: 0} = log] =
               logs_for(created_by_id)

      assert [%{"success" => true, "invitationId" => invitation_id}] = log.results["items"]
      assert invitation_id == invitation.id

      assert %Notification{body: "Successfully processed 1 invitations out of 1"} =
               Repo.get_by(Notification, principal_id: created_by_id)

      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end

    test "refuses a Waitlist entry id and issues nothing" do
      created_by_id = insert_principal!("refusal-admin@example.com")
      waitlist_entry = insert_waitlist_entry!("attended@example.com", "attended")

      args = %{
        "invites" => [waitlist_entry.id],
        "user" => %{"id" => created_by_id, "email" => "refusal-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      refute Repo.get_by(Invitation, email: "attended@example.com")
      assert %WaitlistEntry{status: "attended"} = Repo.get(WaitlistEntry, waitlist_entry.id)
      assert [] = all_enqueued(worker: Dhc.Email.Worker)

      assert [%ProcessingLog{success_count: 0, failure_count: 1} = log] =
               logs_for(created_by_id)

      assert [%{"success" => false, "error" => error}] = log.results["items"]
      assert error =~ "invalid_invite_shape"
    end

    for standing <- Dhc.Waitlist.Standing.statuses() do
      @standing standing
      test "refuses an email on the Waitlist as #{standing} and records it" do
        created_by_id = insert_principal!("waitlist-refusal-admin@example.com")
        insert_waitlist_entry!("queued@example.com", @standing)

        args = %{
          "invites" => [base_invite("Queued@Example.com")],
          "user" => %{"id" => created_by_id}
        }

        assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

        refute Repo.get_by(Invitation, email: "queued@example.com")
        assert [] = all_enqueued(worker: Dhc.Email.Worker)

        assert [%ProcessingLog{failure_count: 1} = log] = logs_for(created_by_id)
        assert [%{"success" => false, "error" => error}] = log.results["items"]
        assert error =~ "email_on_waitlist"
      end
    end

    test "refuses an email that belongs to a Principal and records it" do
      created_by_id = insert_principal!("principal-refusal-admin@example.com")
      insert_principal!("former-member@example.com")

      args = %{
        "invites" => [base_invite("Former-Member@example.com")],
        "user" => %{"id" => created_by_id}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      refute Repo.get_by(Invitation, email: "former-member@example.com")

      assert [%ProcessingLog{failure_count: 1} = log] = logs_for(created_by_id)
      assert [%{"success" => false, "error" => error}] = log.results["items"]
      assert error =~ "email_is_principal"
    end

    test "replaying the same Oban job does not reissue an already completed invitation" do
      created_by_id = insert_principal!("replay-admin@example.com")

      args = %{
        "invites" => [
          %{
            "firstName" => "Ada",
            "lastName" => "Lovelace",
            "email" => "replay-invite@example.com",
            "phoneNumber" => "+353810000001",
            "dateOfBirth" => "1990-01-01"
          }
        ],
        "user" => %{"id" => created_by_id, "email" => "replay-admin@example.com"}
      }

      job = %Oban.Job{
        id: 42,
        attempt: 1,
        queue: "invitations",
        worker: inspect(BulkInviteWorker),
        args: args
      }

      assert :ok = BulkInviteWorker.perform(job)
      assert :ok = BulkInviteWorker.perform(%{job | attempt: 2})

      assert Repo.aggregate(
               from(i in Invitation, where: i.email == "replay-invite@example.com"),
               :count
             ) == 1

      assert [_job] = all_enqueued(worker: Dhc.Email.Worker)
    end
  end

  describe "perform/1 duplicate rejection" do
    test "records a per-invite failure and leaves the existing pending invitation untouched" do
      created_by_id = insert_principal!("dup-admin@example.com")

      invite = %{
        "firstName" => "Ada",
        "lastName" => "Lovelace",
        "email" => "already-pending@example.com",
        "phoneNumber" => "+353810000001",
        "dateOfBirth" => "1990-01-01"
      }

      assert {:ok, original_id} =
               Repository.insert_pending_invitation(invite, nil, created_by_id)

      args = %{
        # Different casing on purpose: rejection must be case-insensitive.
        "invites" => [%{invite | "email" => "Already-Pending@example.com"}],
        "user" => %{"id" => created_by_id, "email" => "dup-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      # No second invitation row was created for the email (citext match).
      invitations =
        Repo.all(from(i in Invitation, where: i.email == "already-pending@example.com"))

      assert [%Invitation{id: ^original_id, status: "pending"}] = invitations

      # The duplicate surfaced as a refused entry in the processing log.
      assert [log] = logs_for(created_by_id)
      assert log.total_count == 1
      assert log.success_count == 0
      assert log.failure_count == 1

      assert [%{"success" => false, "error" => error}] = log.results["items"]
      assert error =~ "duplicate_pending_invitation"

      # No invite email was enqueued for the rejected duplicate.
      assert [] = all_enqueued(worker: Dhc.Email.Worker)
    end

    test "processes the rest of the batch when one invite is a duplicate" do
      created_by_id = insert_principal!("mixed-admin@example.com")

      pending_invite = %{
        "firstName" => "Ada",
        "lastName" => "Lovelace",
        "email" => "taken@example.com",
        "phoneNumber" => "+353810000001",
        "dateOfBirth" => "1990-01-01"
      }

      fresh_invite = %{
        "firstName" => "Grace",
        "lastName" => "Hopper",
        "email" => "fresh@example.com",
        "phoneNumber" => "+353810000002",
        "dateOfBirth" => "1990-01-01"
      }

      assert {:ok, _pending_id} =
               Repository.insert_pending_invitation(pending_invite, nil, created_by_id)

      args = %{
        "invites" => [pending_invite, fresh_invite],
        "user" => %{"id" => created_by_id, "email" => "mixed-admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      # One processing-log entry per invite: the refusal and the issue.
      assert logs_for(created_by_id)
             |> Enum.map(&{&1.success_count, &1.failure_count})
             |> Enum.sort() == [{0, 1}, {1, 0}]

      assert %Invitation{status: "pending"} =
               Repo.get_by!(Invitation, email: "fresh@example.com")

      # Only the fresh invite got an email.
      assert [%Oban.Job{args: email_args}] = all_enqueued(worker: Dhc.Email.Worker)
      assert email_args["email"] == "fresh@example.com"
    end
  end

  defp base_invite(email, overrides \\ %{}) do
    Map.merge(
      %{
        "firstName" => "Ada",
        "lastName" => "Lovelace",
        "email" => email,
        "phoneNumber" => "+353810000001",
        "dateOfBirth" => "1990-01-01"
      },
      overrides
    )
  end

  defp insert_principal!(email) do
    id = Ecto.UUID.generate()

    {:ok, _principal} = Dhc.Auth.register_principal_with_id(id, %{email: email})

    id
  end

  defp insert_waitlist_entry!(email, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %WaitlistEntry{
      email: email,
      status: status,
      removed_at: if(status == "removed", do: now),
      initial_registration_date: now,
      last_status_change: now
    }
    |> Repo.insert!()
  end

  defp logs_for(principal_id) do
    Repo.all(from(l in ProcessingLog, where: l.principal_id == ^principal_id))
  end
end
