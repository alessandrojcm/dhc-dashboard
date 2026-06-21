defmodule DhcWeb.WorkshopsControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.WorkshopFixtures

  defmodule Verifier do
    Enum.each(~w(workshop_coordinator president admin beginners_coordinator member), fn role ->
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

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

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
end
