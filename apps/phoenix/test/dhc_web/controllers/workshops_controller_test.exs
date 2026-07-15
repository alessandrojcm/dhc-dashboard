defmodule DhcWeb.WorkshopsControllerTest do
  @moduledoc """
  Request/contract tests for the Workshop read endpoints: calendar (issue #145),
  member list (issue #144), and attendee/refund management read (issue #146).

  Covers RBAC for coordinator endpoints, member-safe status filtering,
  current-user state, and the normalized participant DTO for attendees/refunds.
  The underlying read-model behavior is covered by `Dhc.WorkshopsTest` (issue #143).
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopFixtures

  @member_user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"
  @coordinator_user_id "33333333-3333-3333-3333-333333333333"

  # The canonical coordinator management roles (mirrors
  # `Dhc.Workshops.coordinator_management_roles/0` and the corrected RLS policy).
  @allowed_roles ~w(workshop_coordinator president admin)
  @rejected_roles ~w(beginners_coordinator member committee_coordinator coach treasurer)

  # In-test JWT verifier: each role gets a deterministic token. The claims
  # shape mirrors what `DhcWeb.Plugs.RequireAuth` reads (`roles`).
  defmodule Verifier do
    for role <-
          ~w(workshop_coordinator president admin beginners_coordinator member committee_coordinator coach treasurer) do
      def verify(unquote("#{role}-token")) do
        sub =
          case unquote(role) do
            "member" -> "11111111-1111-1111-1111-111111111111"
            _ -> "33333333-3333-3333-3333-333333333333"
          end

        {:ok,
         %{
           sub: sub,
           email: "#{unquote(role)}@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end

    def verify("bad-token"), do: {:error, :invalid_token}
    def verify(_token), do: {:error, :invalid_token}
  end

  defmodule StripeClient do
    def request(method: :post, url: "/v1/payment_intents", body: body) do
      Application.put_env(:dhc, :last_workshop_stripe_request, {:create_payment_intent, body})

      case Application.get_env(:dhc, :workshop_stripe_create_response, :ok) do
        :ok ->
          {:ok,
           %{
             "id" => "pi_test_member",
             "client_secret" => "pi_test_member_secret",
             "amount" => form_value(body, :amount),
             "currency" => form_value(body, :currency),
             "status" => "requires_payment_method",
             "metadata" => %{}
           }}

        other ->
          other
      end
    end

    def request(method: :get, url: "/v1/payment_intents/" <> payment_intent_id) do
      case Application.get_env(:dhc, :workshop_stripe_retrieve_response) do
        nil ->
          {:ok,
           %{
             "id" => payment_intent_id,
             "status" => "succeeded",
             "amount" => 1000,
             "currency" => "eur",
             "metadata" => %{
               "type" => "workshop_registration",
               "actor_type" => "member",
               "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_workshop_id),
               "user_id" => "11111111-1111-1111-1111-111111111111"
             }
           }}

        other ->
          other
      end
    end

    def request(method: :post, url: "/v1/refunds", body: body) do
      Application.put_env(:dhc, :last_workshop_stripe_refund_request, body)
      {:ok, %{"id" => "re_test_member"}}
    end

    defp form_value(body, key) do
      body
      |> Enum.find_value(fn
        {^key, value} -> value
        _ -> nil
      end)
    end
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    original_stripe = Application.get_env(:dhc, :workshop_stripe_client)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    Application.put_env(:dhc, :workshop_stripe_client, StripeClient)
    insert_auth_user_and_profile(@member_user_id, "Current", "Member")
    insert_auth_user_and_profile(@other_user_id, "Other", "Member")
    insert_auth_user_and_profile(@coordinator_user_id, "Workshop", "Coordinator")

    on_exit(fn ->
      Application.put_env(:dhc, :auth_verifier, original)
      Application.put_env(:dhc, :workshop_stripe_client, original_stripe)
      Application.delete_env(:dhc, :workshop_stripe_create_response)
      Application.delete_env(:dhc, :workshop_stripe_retrieve_response)
      Application.delete_env(:dhc, :workshop_stripe_workshop_id)
      Application.delete_env(:dhc, :last_workshop_stripe_request)
      Application.delete_env(:dhc, :last_workshop_stripe_refund_request)
    end)
  end

  # `:binary_id` PKs autogenerate as 16-byte binaries on the inserted struct;
  # normalize to the string UUID form for URL interpolation and assertions.
  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── Calendar ──────────────────────────────────────────────────────────

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

  # ── Member list ───────────────────────────────────────────────────────

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

  # ── Interest toggle ───────────────────────────────────────────────────

  describe "toggle_interest" do
    test "returns 401 without a bearer token", %{conn: conn} do
      workshop = insert_workshop(status: "planned")

      conn = post(conn, "/api/workshops/#{to_uuid(workshop.id)}/interest")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "expresses and withdraws the authenticated member's interest", %{conn: conn} do
      workshop = insert_workshop(status: "planned")

      express_conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/interest")

      assert %{
               "data" => %{
                 "interested" => true,
                 "action" => "expressed",
                 "message" => "Interest expressed successfully"
               }
             } = json_response(express_conn, 200)

      [payload] =
        build_conn()
        |> auth_conn("member")
        |> get("/api/workshops", status: "planned")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert payload["currentUserInterest"] == true
      assert payload["interestCount"] == 1

      withdraw_conn =
        build_conn()
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/interest")

      assert %{
               "data" => %{
                 "interested" => false,
                 "action" => "withdrawn",
                 "message" => "Interest withdrawn successfully"
               }
             } = json_response(withdraw_conn, 200)

      [payload] =
        build_conn()
        |> auth_conn("member")
        |> get("/api/workshops", status: "planned")
        |> json_response(200)
        |> get_in(["data", "workshops"])

      assert payload["currentUserInterest"] == false
      assert payload["interestCount"] == 0
    end

    test "rejects interest in published Workshops", %{conn: conn} do
      workshop = insert_workshop(status: "published")

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/interest")

      assert %{"errors" => %{"detail" => "Can only express interest in planned workshops"}} =
               json_response(conn, 422)
    end

    test "returns 404 for an unknown Workshop id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{Ecto.UUID.generate()}/interest")

      assert %{"errors" => %{"detail" => "Workshop not found"}} = json_response(conn, 404)
    end
  end

  # ── Management lifecycle ──────────────────────────────────────────────

  describe "management endpoints — RBAC" do
    test "allows workshop_coordinator, president, and admin to create" do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/workshops", valid_workshop_payload(%{"title" => "#{role} Workshop"}))

        assert %{"data" => %{"workshop" => %{"title" => title}}} = json_response(conn, 201)
        assert title == "#{role} Workshop"
      end
    end

    test "rejects unrelated roles and missing tokens" do
      conn = post(build_conn(), "/api/workshops", valid_workshop_payload())
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)

      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/workshops", valid_workshop_payload())

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end
  end

  describe "management endpoints — create/update/delete/publish/cancel" do
    test "creates planned Workshops from camelCase input and returns management DTO", %{
      conn: conn
    } do
      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> post("/api/workshops", valid_workshop_payload())

      assert %{"data" => %{"workshop" => workshop}} = json_response(conn, 201)

      assert workshop["title"] == "API Workshop"
      assert workshop["status"] == "planned"
      assert workshop["startDate"] == "2026-09-01T10:00:00Z"
      assert workshop["maxCapacity"] == 20
      assert workshop["priceMember"] == 1000.0
      assert workshop["createdBy"]
      assert workshop["interestCount"] == 0
    end

    test "updates planned Workshops but does not allow direct status writes", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture(status: "planned")

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}", %{
          "title" => "Updated API Workshop",
          "status" => "cancelled"
        })

      assert %{"data" => %{"workshop" => payload}} = json_response(conn, 200)
      assert payload["title"] == "Updated API Workshop"
      assert payload["status"] == "planned"
    end

    test "allows published pricing edits only while there are no active registrations", %{
      conn: conn
    } do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1000.0)

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}", %{"priceMember" => 1200.0})

      assert %{"data" => %{"workshop" => %{"priceMember" => 1200.0}}} = json_response(conn, 200)

      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed"
      )

      conn =
        build_conn()
        |> auth_conn("workshop_coordinator")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}", %{"priceMember" => 1300.0})

      assert %{
               "errors" => %{
                 "detail" => "Cannot change pricing when there are active registrations"
               }
             } =
               json_response(conn, 422)
    end

    test "publishes planned Workshops and cancels published Workshops", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture(status: "planned")

      publish_conn =
        conn
        |> auth_conn("president")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/publish")

      assert %{"data" => %{"workshop" => %{"status" => "published"}}} =
               json_response(publish_conn, 200)

      cancel_conn =
        build_conn()
        |> auth_conn("president")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/cancel")

      assert %{"data" => %{"workshop" => %{"status" => "cancelled"}}} =
               json_response(cancel_conn, 200)
    end

    test "deletes planned Workshops with 204 and rejects published deletes", %{conn: conn} do
      planned = WorkshopFixtures.workshop_fixture(status: "planned")
      published = WorkshopFixtures.workshop_fixture(status: "published")

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/workshops/#{to_uuid(planned.id)}")

      assert response(conn, 204) == ""

      conn =
        build_conn()
        |> auth_conn("admin")
        |> delete("/api/workshops/#{to_uuid(published.id)}")

      assert %{"errors" => %{"detail" => "Only planned workshops can be deleted"}} =
               json_response(conn, 422)
    end

    test "returns 404 for unknown Workshop ids", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/workshops/#{missing_id}/publish")

      assert %{"errors" => %{"detail" => "Workshop not found"}} = json_response(conn, 404)
    end
  end

  # ── Attendees RBAC ────────────────────────────────────────────────────

  describe "attendees — RBAC" do
    test "allows workshop_coordinator, president, and admin", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      for role <- @allowed_roles do
        response =
          build_conn()
          |> auth_conn(role)
          |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")
          |> json_response(200)

        assert %{"data" => %{"workshop" => _, "attendees" => _, "refunds" => _}} = response
      end
    end

    test "rejects beginners_coordinator with 403 (historical drift not reproduced)" do
      workshop = WorkshopFixtures.workshop_fixture()

      conn =
        build_conn()
        |> auth_conn("beginners_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      # The old `club_activity_registrations` RLS policy granted
      # beginners_coordinator full registration visibility. That was drift
      # (see Dhc.Workshops moduledoc). Phoenix must NOT reproduce it.
      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "rejects other unrelated roles with 403" do
      workshop = WorkshopFixtures.workshop_fixture()

      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end

    test "returns 401 without a bearer token" do
      workshop = WorkshopFixtures.workshop_fixture()

      conn = build_conn() |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token" do
      workshop = WorkshopFixtures.workshop_fixture()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── 404 ───────────────────────────────────────────────────────────────

  describe "attendees — missing Workshop" do
    test "returns 404 for an unknown Workshop id", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{missing_id}/attendees")

      assert %{"errors" => %{"detail" => "Workshop not found"}} = json_response(conn, 404)
    end
  end

  # ── Combined payload + Workshop summary ───────────────────────────────

  describe "attendees — payload shape" do
    test "returns workshop summary, attendees, and refunds together", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture(title: "Managed", status: "published")

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Member", last_name: "One")

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{
               "data" => %{
                 "workshop" => workshop_payload,
                 "attendees" => attendees,
                 "refunds" => refunds
               }
             } = json_response(conn, 200)

      assert length(attendees) == 1
      assert length(refunds) == 1

      # Workshop summary uses Workshop vocabulary + camelCase, not club_activity*.
      assert workshop_payload["title"] == "Managed"
      assert workshop_payload["status"] == "published"
      assert workshop_payload["id"] == to_uuid(workshop.id)
      assert Map.has_key?(workshop_payload, "startDate")
      assert Map.has_key?(workshop_payload, "refundDays")
      assert Map.has_key?(workshop_payload, "interestCount")
      assert Map.has_key?(workshop_payload, "pendingRegistrationCount")
      assert Map.has_key?(workshop_payload, "confirmedRegistrationCount")

      refute Map.has_key?(workshop_payload, "club_activity_id")
      refute Map.has_key?(workshop_payload, "start_date")
    end
  end

  # ── Attendee status filtering + normalized participant ────────────────

  describe "attendees — status filtering and participant normalization" do
    test "returns only confirmed and pending attendees", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: confirmed_uid} =
        WorkshopFixtures.member_fixture(first_name: "Con", last_name: "Firmed")

      %{auth_user_id: pending_uid} =
        WorkshopFixtures.member_fixture(first_name: "Pen", last_name: "Ding")

      %{auth_user_id: cancelled_uid} =
        WorkshopFixtures.member_fixture(first_name: "Can", last_name: "Celled")

      %{auth_user_id: refunded_uid} =
        WorkshopFixtures.member_fixture(first_name: "Ref", last_name: "Unded")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: confirmed_uid,
        status: "confirmed"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: pending_uid,
        status: "pending"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: cancelled_uid,
        status: "cancelled"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: refunded_uid,
        status: "refunded"
      )

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"attendees" => attendees}} = json_response(conn, 200)

      statuses = Enum.map(attendees, & &1["status"]) |> Enum.sort()
      assert statuses == ["confirmed", "pending"]
      assert length(attendees) == 2
    end

    test "normalizes a member participant with displayName and no email", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Ada", last_name: "Lovelace")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed"
      )

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"attendees" => [attendee]}} = json_response(conn, 200)

      assert attendee["participant"] == %{
               "type" => "member",
               "displayName" => "Ada Lovelace",
               "email" => nil
             }

      # camelCase attendee fields
      assert Map.has_key?(attendee, "attendanceStatus")
      assert Map.has_key?(attendee, "registeredAt")

      # Storage join shapes must not leak.
      refute Map.has_key?(attendee, "user_profiles")
      refute Map.has_key?(attendee, "external_users")
      refute Map.has_key?(attendee, "member_first_name")
      refute Map.has_key?(attendee, "external_user_id")
    end

    test "normalizes an external participant with displayName and email", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      ext =
        WorkshopFixtures.external_user_fixture(
          first_name: "Grace",
          last_name: "Hopper",
          email: "grace@example.com"
        )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: ext.id,
        status: "confirmed"
      )

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"attendees" => [attendee]}} = json_response(conn, 200)

      assert attendee["participant"] == %{
               "type" => "external",
               "displayName" => "Grace Hopper",
               "email" => "grace@example.com"
             }
    end

    test "orders attendees by registeredAt ascending", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: u1} = WorkshopFixtures.member_fixture(first_name: "First", last_name: "Reg")

      %{auth_user_id: u2} =
        WorkshopFixtures.member_fixture(first_name: "Second", last_name: "Reg")

      earlier = ~U[2026-06-01 10:00:00Z]
      later = ~U[2026-06-02 10:00:00Z]

      # Insert in reverse chronological order to prove the read orders by
      # created_at, not insertion order.
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u2,
        status: "confirmed",
        created_at: later
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        status: "confirmed",
        created_at: earlier
      )

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"attendees" => attendees}} = json_response(conn, 200)

      assert Enum.map(attendees, & &1["participant"]["displayName"]) == [
               "First Reg",
               "Second Reg"
             ]
    end
  end

  # ── Refunds ───────────────────────────────────────────────────────────

  describe "attendees — refund inclusion and participant normalization" do
    test "includes refunds regardless of refund status", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()

      reg1 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u1,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg1.id, status: "pending")

      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()

      reg2 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u2,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg2.id, status: "completed")

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"refunds" => refunds}} = json_response(conn, 200)

      assert length(refunds) == 2
      statuses = Enum.map(refunds, & &1["status"]) |> Enum.sort()
      assert statuses == ["completed", "pending"]
    end

    test "normalizes a member participant on a refund", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Alan", last_name: "Turing")

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"refunds" => [refund]}} = json_response(conn, 200)

      assert refund["participant"] == %{
               "type" => "member",
               "displayName" => "Alan Turing",
               "email" => nil
             }

      # camelCase refund fields, storage join shapes absent.
      assert Map.has_key?(refund, "registrationId")
      assert Map.has_key?(refund, "refundAmount")
      assert Map.has_key?(refund, "requestedAt")
      refute Map.has_key?(refund, "user_profiles")
      refute Map.has_key?(refund, "external_users")
      refute Map.has_key?(refund, "club_activity_registrations")
    end

    test "normalizes an external participant on a refund", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      ext =
        WorkshopFixtures.external_user_fixture(
          first_name: "Katherine",
          last_name: "Johnson",
          email: "katherine@example.com"
        )

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          external_user_id: ext.id,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"refunds" => [refund]}} = json_response(conn, 200)

      assert refund["participant"] == %{
               "type" => "external",
               "displayName" => "Katherine Johnson",
               "email" => "katherine@example.com"
             }
    end

    test "returns empty attendees and refunds for a Workshop with neither", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> get("/api/workshops/#{to_uuid(workshop.id)}/attendees")

      assert %{"data" => %{"attendees" => [], "refunds" => []}} = json_response(conn, 200)
    end
  end

  # ── Attendance ──────────────────────────────────────────────────────────

  describe "attendance" do
    test "atomically marks active attendees after the Workshop has started", %{conn: conn} do
      workshop =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second),
          end_date: DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
        )

      %{auth_user_id: confirmed_user} = WorkshopFixtures.member_fixture()
      %{auth_user_id: pending_user} = WorkshopFixtures.member_fixture()

      confirmed =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: confirmed_user,
          status: "confirmed"
        )

      pending =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: pending_user,
          status: "pending"
        )

      conn =
        conn
        |> auth_conn("workshop_coordinator")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}/attendance", %{
          "updates" => [
            %{"registrationId" => to_uuid(confirmed.id), "attendanceStatus" => "attended"},
            %{
              "registrationId" => to_uuid(pending.id),
              "attendanceStatus" => "excused",
              "notes" => "Injured"
            }
          ]
        })

      assert %{"data" => %{"registrations" => registrations}} = json_response(conn, 200)

      assert Enum.map(registrations, & &1["attendanceStatus"]) == ["attended", "excused"]
      assert Enum.at(registrations, 1)["attendanceNotes"] == "Injured"
      assert Enum.all?(registrations, &(&1["attendanceMarkedBy"] == @coordinator_user_id))
    end

    test "rejects the entire batch when it includes a non-active registration", %{conn: conn} do
      workshop =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second),
          end_date: DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
        )

      %{auth_user_id: active_user} = WorkshopFixtures.member_fixture()
      %{auth_user_id: cancelled_user} = WorkshopFixtures.member_fixture()

      active =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: active_user,
          status: "confirmed"
        )

      cancelled =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: cancelled_user,
          status: "cancelled"
        )

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}/attendance", %{
          "updates" => [
            %{"registrationId" => to_uuid(active.id), "attendanceStatus" => "attended"},
            %{"registrationId" => to_uuid(cancelled.id), "attendanceStatus" => "noShow"}
          ]
        })

      assert %{
               "errors" => %{
                 "detail" => "Attendance updates must target active Workshop attendees"
               }
             } =
               json_response(conn, 422)

      assert %{attendance_status: "pending"} = Repo.get(Dhc.Workshops.Registration, active.id)
    end

    test "rejects attendance updates before the Workshop has started", %{conn: conn} do
      workshop =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
        )

      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: user_id,
          status: "confirmed"
        )

      conn =
        conn
        |> auth_conn("president")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}/attendance", %{
          "updates" => [
            %{"registrationId" => to_uuid(registration.id), "attendanceStatus" => "attended"}
          ]
        })

      assert %{
               "errors" => %{
                 "detail" => "Cannot update attendance before the Workshop has started"
               }
             } =
               json_response(conn, 422)
    end

    test "requires a Workshop coordinator management role", %{conn: conn} do
      workshop = WorkshopFixtures.workshop_fixture()

      conn =
        conn
        |> auth_conn("beginners_coordinator")
        |> patch("/api/workshops/#{to_uuid(workshop.id)}/attendance", %{"updates" => []})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  # ── Member registration ───────────────────────────────────────────────

  describe "member registration" do
    test "creates a PaymentIntent after duplicate and capacity checks", %{conn: conn} do
      workshop = insert_workshop(status: "published", max_capacity: 2)

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/registration/payment-intent", %{
          "amount" => 1000,
          "currency" => "eur",
          "customerId" => "cus_test"
        })

      assert %{
               "data" => %{
                 "clientSecret" => "pi_test_member_secret",
                 "paymentIntentId" => "pi_test_member"
               }
             } = json_response(conn, 200)

      assert {:create_payment_intent, body} =
               Application.fetch_env!(:dhc, :last_workshop_stripe_request)

      assert {:amount, 1000} in body
      assert {:currency, "eur"} in body
      assert {:customer, "cus_test"} in body
      assert {"metadata[workshop_id]", to_uuid(workshop.id)} in body
      assert {"metadata[user_id]", @member_user_id} in body
    end

    test "does not create a PaymentIntent when the Workshop is full", %{conn: conn} do
      workshop = insert_workshop(status: "published", max_capacity: 1)

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: @other_user_id,
        status: "confirmed"
      )

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/registration/payment-intent", %{
          "amount" => 1000
        })

      assert %{"errors" => %{"detail" => "Workshop is full"}} = json_response(conn, 409)
      assert Application.get_env(:dhc, :last_workshop_stripe_request) == nil
    end

    test "completes a succeeded PaymentIntent into a confirmed registration", %{conn: conn} do
      workshop = insert_workshop(status: "published", max_capacity: 2)
      Application.put_env(:dhc, :workshop_stripe_workshop_id, to_uuid(workshop.id))

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/registration/complete", %{
          "paymentIntentId" => "pi_succeeded"
        })

      assert %{"data" => %{"registration" => registration}} = json_response(conn, 201)
      assert registration["status"] == "confirmed"

      assert %{status: "confirmed"} =
               Dhc.Workshops.current_user_registration(to_uuid(workshop.id), @member_user_id)
    end

    test "rejects completion when PaymentIntent has not succeeded", %{conn: conn} do
      workshop = insert_workshop(status: "published", max_capacity: 2)

      Application.put_env(:dhc, :workshop_stripe_retrieve_response, {
        :ok,
        %{
          "id" => "pi_processing",
          "status" => "processing",
          "amount" => 1000,
          "currency" => "eur",
          "metadata" => %{
            "type" => "workshop_registration",
            "actor_type" => "member",
            "workshop_id" => to_uuid(workshop.id),
            "user_id" => @member_user_id
          }
        }
      })

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/workshops/#{to_uuid(workshop.id)}/registration/complete", %{
          "paymentIntentId" => "pi_processing"
        })

      assert %{"errors" => %{"detail" => "Payment not completed"}} = json_response(conn, 422)
    end

    test "cancels the current member active registration", %{conn: conn} do
      workshop = insert_workshop(status: "published")

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: @member_user_id,
          status: "confirmed"
        )

      conn =
        conn
        |> auth_conn("member")
        |> delete("/api/workshops/#{to_uuid(workshop.id)}/registration")

      assert %{
               "data" => %{
                 "registration" => %{"id" => id, "status" => "cancelled"},
                 "refundProcessed" => false
               }
             } = json_response(conn, 200)

      assert id == to_uuid(registration.id)
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

  defp valid_workshop_payload(overrides \\ %{}) do
    %{
      "title" => "API Workshop",
      "description" => "Created through Phoenix",
      "location" => "Main Hall",
      "startDate" => "2026-09-01T10:00:00Z",
      "endDate" => "2026-09-01T12:00:00Z",
      "maxCapacity" => 20,
      "priceMember" => 1000.0,
      "priceNonMember" => 2000.0,
      "isPublic" => false,
      "refundDays" => 3,
      "announceDiscord" => false,
      "announceEmail" => false
    }
    |> Map.merge(overrides)
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
