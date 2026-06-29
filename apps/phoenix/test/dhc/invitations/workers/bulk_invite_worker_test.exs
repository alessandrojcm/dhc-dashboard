defmodule Dhc.Invitations.BulkInviteWorkerTest do
  use Dhc.DataCase, async: false

  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Notifications.Notification
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  setup do
    original_stripe_api_url = Application.get_env(:dhc, :stripe_api_url)
    original_supabase_url = Application.get_env(:dhc, :supabase_url)
    original_service_role_key = Application.get_env(:dhc, :supabase_service_role_key)

    on_exit(fn ->
      Application.put_env(:dhc, :stripe_api_url, original_stripe_api_url)
      Application.put_env(:dhc, :supabase_url, original_supabase_url)
      Application.put_env(:dhc, :supabase_service_role_key, original_service_role_key)
    end)

    :ok
  end

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
    test "resolves a waitlist id and creates the invitation pipeline" do
      created_by_id = insert_auth_user!("admin@example.com")
      invited_auth_user_id = insert_auth_user!("ada@example.com")
      waitlist_entry = insert_waitlist_entry!("ada@example.com")

      insert_waitlist_profile!(waitlist_entry.id,
        first_name: "Ada",
        last_name: "Lovelace",
        phone_number: "+353810000001",
        date_of_birth: ~D[1990-01-01]
      )

      stripe_bypass = Bypass.open()
      supabase_bypass = Bypass.open()

      Application.put_env(:dhc, :stripe_api_url, "http://localhost:#{stripe_bypass.port}")
      Application.put_env(:dhc, :supabase_url, "http://localhost:#{supabase_bypass.port}")
      Application.put_env(:dhc, :supabase_service_role_key, "test-service-role-key")

      Bypass.expect(stripe_bypass, "POST", "/v1/customers", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert body =~ "email=ada%40example.com"
        assert body =~ "name=Ada+Lovelace"
        assert body =~ "metadata%5Binvited_by%5D=#{created_by_id}"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"id":"cus_waitlist_123"}))
      end)

      Bypass.expect(supabase_bypass, "POST", "/auth/v1/admin/users", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-service-role-key"]
        assert Plug.Conn.get_req_header(conn, "apikey") == ["test-service-role-key"]
        assert body =~ ~s("email":"ada@example.com")
        assert body =~ ~s("first_name":"Ada")
        assert body =~ ~s("last_name":"Lovelace")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"id":"#{invited_auth_user_id}"}))
      end)

      args = %{
        "invites" => [waitlist_entry.id],
        "user" => %{"id" => created_by_id, "email" => "admin@example.com"}
      }

      assert :ok = BulkInviteWorker.perform(%Oban.Job{args: args})

      assert %Invitation{} = invitation = Repo.get_by(Invitation, email: "ada@example.com")
      assert invitation.status == "pending"
      assert invitation.waitlist_id == waitlist_entry.id
      assert invitation.user_id == invited_auth_user_id
      assert invitation.created_by == created_by_id

      assert %WaitlistEntry{status: "invited"} = Repo.get(WaitlistEntry, waitlist_entry.id)

      assert %UserProfile{} =
               profile = Repo.get_by(UserProfile, supabase_user_id: invited_auth_user_id)

      assert profile.first_name == "Ada"
      assert profile.last_name == "Lovelace"
      assert profile.phone_number == "+353810000001"
      assert profile.date_of_birth == ~D[1990-01-01]
      assert profile.customer_id == "cus_waitlist_123"
      assert profile.waitlist_id == waitlist_entry.id
      assert profile.is_active == false

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
    end
  end

  defp insert_auth_user!(email) do
    id = Ecto.UUID.generate()

    Repo.insert_all(
      "users",
      [
        [
          id: Ecto.UUID.dump!(id),
          aud: "authenticated",
          role: "authenticated",
          email: email
        ]
      ],
      prefix: "auth"
    )

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
