defmodule DhcWeb.WorkshopsControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopFixtures

  @member_user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  defmodule Verifier do
    Enum.each(~w(workshop_coordinator president admin beginners_coordinator), fn role ->
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: Ecto.UUID.generate(),
           email: "#{unquote(role)}@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end)

    def verify("member-token") do
      {:ok,
       %{
         sub: "11111111-1111-1111-1111-111111111111",
         email: "member@example.com",
         roles: [],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    insert_auth_user_and_profile(@member_user_id, "Current", "Member")
    insert_auth_user_and_profile(@other_user_id, "Other", "Member")

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
  end

  describe "calendar" do
    test "allows workshop_coordinator, president, and admin", %{conn: _conn} do
      for role <- ~w(workshop_coordinator president admin) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/workshops/calendar")

        assert %{"data" => %{"workshops" => []}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/workshops/calendar")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for unrelated roles, including beginners_coordinator", %{conn: _conn} do
      for role <- ~w(beginners_coordinator member) do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get("/api/workshops/calendar")

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end

    test "returns non-cancelled workshops in deterministic start_date order", %{conn: conn} do
      later =
        WorkshopFixtures.workshop_fixture(
          title: "Later",
          status: "published",
          start_date: ~U[2026-08-01 10:00:00Z],
          end_date: ~U[2026-08-01 12:00:00Z]
        )

      earlier =
        WorkshopFixtures.workshop_fixture(
          title: "Earlier",
          status: "planned",
          start_date: ~U[2026-06-01 10:00:00Z],
          end_date: ~U[2026-06-01 12:00:00Z]
        )

      WorkshopFixtures.workshop_fixture(title: "Cancelled", status: "cancelled")

      conn =
        conn
        |> put_req_header("authorization", "Bearer workshop_coordinator-token")
        |> get("/api/workshops/calendar")

      assert %{"data" => %{"workshops" => workshops}} = json_response(conn, 200)

      assert Enum.map(workshops, & &1["title"]) == ["Earlier", "Later"]
      assert Enum.map(workshops, & &1["id"]) == [earlier.id, later.id]
    end

    test "returns calendar DTO fields, counts, and no current-user artifacts", %{conn: conn} do
      workshop =
        WorkshopFixtures.workshop_fixture(
          title: "Demand Workshop",
          description: "Coordinator view",
          location: "Main Hall",
          status: "published",
          start_date: ~U[2026-07-01 10:00:00Z],
          end_date: ~U[2026-07-01 12:00:00Z],
          max_capacity: 12,
          price_member: 1500.0,
          price_non_member: 2500.0,
          is_public: true,
          refund_days: 5,
          announce_discord: true,
          announce_email: true
        )

      %{auth_user_id: interested_1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: interested_2} = WorkshopFixtures.member_fixture()
      WorkshopFixtures.interest_fixture(workshop.id, interested_1)
      WorkshopFixtures.interest_fixture(workshop.id, interested_2)

      %{auth_user_id: pending_user} = WorkshopFixtures.member_fixture()
      %{auth_user_id: confirmed_user} = WorkshopFixtures.member_fixture()
      %{auth_user_id: cancelled_user} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: pending_user,
        status: "pending"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: confirmed_user,
        status: "confirmed"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: cancelled_user,
        status: "cancelled"
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/workshops/calendar")

      assert %{"data" => %{"workshops" => [item]}} = json_response(conn, 200)

      assert item == %{
               "id" => workshop.id,
               "title" => "Demand Workshop",
               "description" => "Coordinator view",
               "location" => "Main Hall",
               "startDate" => "2026-07-01T10:00:00Z",
               "endDate" => "2026-07-01T12:00:00Z",
               "maxCapacity" => 12,
               "priceMember" => 1500.0,
               "priceNonMember" => 2500.0,
               "isPublic" => true,
               "refundDays" => 5,
               "status" => "published",
               "announceDiscord" => true,
               "announceEmail" => true,
               "createdBy" => nil,
               "interestCount" => 2,
               "pendingRegistrationCount" => 1,
               "confirmedRegistrationCount" => 1
             }

      refute Map.has_key?(item, "userInterest")
      refute Map.has_key?(item, "userRegistrations")
      refute Map.has_key?(item, "currentUserRegistration")
      refute Map.has_key?(item, "attendees")
    end
  end

  describe "list" do
    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/workshops")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "defaults to planned and published workshops ordered by start date", %{conn: conn} do
      now = ~U[2026-01-01 10:00:00Z]

      published =
        insert_workshop(
          title: "Published Workshop",
          status: "published",
          start_date: DateTime.add(now, 2, :hour)
        )

      planned =
        insert_workshop(
          title: "Planned Workshop",
          status: "planned",
          start_date: DateTime.add(now, 1, :hour)
        )

      insert_workshop(title: "Finished Workshop", status: "finished")
      insert_workshop(title: "Cancelled Workshop", status: "cancelled")

      workshops =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert Enum.map(workshops, & &1["id"]) == [planned.id, published.id]
      assert Enum.map(workshops, & &1["status"]) == ["planned", "published"]
    end

    test "constrains status filtering to member-safe statuses", %{conn: conn} do
      planned = insert_workshop(title: "Planned", status: "planned")
      insert_workshop(title: "Published", status: "published")
      insert_workshop(title: "Finished", status: "finished")

      planned_only =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops", status: "planned,finished,not-real")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert [%{"id" => id, "status" => "planned"}] = planned_only
      assert id == planned.id

      unsafe_only =
        build_conn()
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops", status: "finished,cancelled")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert unsafe_only == []
    end

    test "includes interest counts and current-user interest state for planned workshops", %{
      conn: conn
    } do
      workshop = insert_workshop(status: "planned")

      WorkshopFixtures.interest_fixture(workshop.id, @member_user_id)
      WorkshopFixtures.interest_fixture(workshop.id, @other_user_id)

      [payload] =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops", status: "planned")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert payload["interestCount"] == 2
      assert payload["currentUserInterest"] == true
      assert payload["currentUserRegistration"] == nil
    end

    test "includes counted registration totals and current-user registration state", %{conn: conn} do
      workshop = insert_workshop(status: "published")

      current_registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: @member_user_id,
          status: "confirmed"
        )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: @other_user_id,
        status: "pending"
      )

      external = WorkshopFixtures.external_user_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: external.id,
        status: "cancelled"
      )

      [payload] =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops", status: "published")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert payload["pendingRegistrationCount"] == 1
      assert payload["confirmedRegistrationCount"] == 1

      assert payload["currentUserRegistration"] == %{
               "id" => current_registration.id,
               "status" => "confirmed"
             }
    end

    test "does not expose attendee identities or storage-shaped join details", %{conn: conn} do
      workshop = insert_workshop(status: "published")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: @other_user_id,
        status: "confirmed"
      )

      [payload] =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get("/api/workshops", status: "published")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      refute Map.has_key?(payload, "attendees")
      refute Map.has_key?(payload, "attendeeCount")
      refute Map.has_key?(payload, "attendee_count")
      refute Map.has_key?(payload, "club_activity_registrations")
      refute Map.has_key?(payload, "memberUserIds")
      refute Map.has_key?(payload, "participant")
      refute Map.has_key?(payload, "createdBy")
      refute Map.has_key?(payload, "announceDiscord")
      assert payload["id"] == workshop.id
    end
  end

  defp insert_workshop(attrs) do
    attrs = Enum.into(attrs, %{})

    start_date =
      attrs
      |> Map.get(:start_date, ~U[2026-01-01 12:00:00Z])
      |> DateTime.truncate(:second)

    attrs
    |> Map.put_new(:end_date, DateTime.add(start_date, 2, :hour))
    |> Map.put(:start_date, start_date)
    |> WorkshopFixtures.workshop_fixture()
  end

  defp insert_auth_user_and_profile(user_id, first_name, last_name) do
    Repo.insert_all(
      "users",
      [
        [
          id: Ecto.UUID.dump!(user_id),
          aud: "authenticated",
          role: "authenticated",
          email:
            "#{String.downcase(first_name)}-#{System.unique_integer([:positive])}@example.com"
        ]
      ],
      prefix: "auth"
    )

    {:ok, _profile} =
      %UserProfile{
        supabase_user_id: user_id,
        first_name: first_name,
        last_name: last_name,
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01],
        gender: "man (cis)",
        pronouns: "he/him",
        is_active: true,
        social_media_consent: "no"
      }
      |> Repo.insert()
  end
end
