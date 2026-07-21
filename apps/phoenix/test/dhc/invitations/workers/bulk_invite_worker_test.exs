defmodule Dhc.Invitations.BulkInviteWorkerTest do
  use Dhc.DataCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Notifications.Broadcaster
  alias Dhc.Notifications.Notification
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  # ALE-162 (ADR 0010): issue time is side-effect free. The worker no longer
  # calls the Supabase admin API, creates a Stripe customer, or inserts a
  # user_profiles row. It only:
  #   - mints a fresh Phoenix UUID for invitation.user_id;
  #   - inserts the pending invitation carrying first/last/phone/DOB;
  #   - enqueues the inviteMember email;
  #   - marks the waitlist entry invited (when the invite came from a waitlist).
  #
  # Acceptance (not the worker) materializes the Principal + UserProfile +
  # MemberProfile + role. The Stripe customer is lazily created by the
  # pricing endpoint and reused by acceptance.

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

  describe "perform/1 waitlist invitations" do
    test "resolves a waitlist id and creates the invitation with no profile or Stripe customer" do
      created_by_id = insert_principal!("admin@example.com")
      waitlist_entry = insert_waitlist_entry!("ada@example.com")

      insert_waitlist_profile!(waitlist_entry.id,
        first_name: "Ada",
        last_name: "Lovelace",
        phone_number: "+353810000001",
        date_of_birth: ~D[1990-01-01]
      )

      args = %{
        "invites" => [waitlist_entry.id],
        "user" => %{"id" => created_by_id, "email" => "admin@example.com"}
      }

      # Subscribe to the admin's Notification realtime topic before perform so
      # the commit-safe broadcast attempt is observable. The bulk invitation
      # workflow must produce exactly one notification_created signal for the
      # admin alongside its existing processing Notification row.
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(created_by_id))

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      assert %Invitation{} = invitation = Repo.get_by(Invitation, email: "ada@example.com")
      assert invitation.status == "pending"
      assert invitation.waitlist_id == waitlist_entry.id
      assert invitation.created_by == created_by_id
      assert invitation.date_of_birth == ~D[1990-01-01]
      assert invitation.first_name == "Ada"
      assert invitation.last_name == "Lovelace"
      assert invitation.phone_number == "+353810000001"

      # ALE-162: user_id is a fresh Phoenix UUID (no auth.users row backs it).
      assert invitation.user_id != nil
      assert Ecto.UUID.cast!(invitation.user_id) == invitation.user_id

      # No user_profiles row was created at issue time.
      refute Repo.exists?(from up in UserProfile, where: up.principal_id == ^invitation.user_id)

      # No Stripe customer was created at issue time.
      assert invitation.stripe_customer_id in [nil, ""]

      # The waitlist entry was marked invited.
      assert %WaitlistEntry{status: "invited"} = Repo.get(WaitlistEntry, waitlist_entry.id)

      # The inviteMember email was enqueued.
      assert [%Oban.Job{args: email_args}] = all_enqueued(worker: Dhc.Email.Worker)
      assert email_args["email"] == "ada@example.com"
      assert email_args["transactional_id"] == "inviteMember"
      assert email_args["data_variables"]["firstName"] == "Ada"
      assert email_args["data_variables"]["lastName"] == "Lovelace"
      assert email_args["data_variables"]["invitationLink"] =~ "/members/signup/#{invitation.id}"

      assert %ProcessingLog{total_count: 1, success_count: 1, failure_count: 0} =
               Repo.get_by(ProcessingLog, user_id: created_by_id)

      assert %Notification{body: body} = Repo.get_by(Notification, user_id: created_by_id)
      assert body == "Successfully processed 1 invitations out of 1"

      # Exactly one commit-safe creation signal for the admin's topic.
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  defp insert_principal!(email) do
    id = Ecto.UUID.generate()

    {:ok, _principal} = Dhc.Auth.register_principal_with_id(id, %{email: email})

    id
  end

  defp insert_waitlist_entry!(email) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %WaitlistEntry{
      email: email,
      status: "waiting",
      initial_registration_date: now,
      last_status_change: now
    }
    |> Repo.insert!()
  end

  defp insert_waitlist_profile!(waitlist_id, attrs) do
    %UserProfile{
      first_name: Keyword.fetch!(attrs, :first_name),
      last_name: Keyword.fetch!(attrs, :last_name),
      phone_number: Keyword.fetch!(attrs, :phone_number),
      date_of_birth: Keyword.fetch!(attrs, :date_of_birth),
      waitlist_id: waitlist_id,
      is_active: false,
      social_media_consent: "no"
    }
    |> Repo.insert!()
  end
end
