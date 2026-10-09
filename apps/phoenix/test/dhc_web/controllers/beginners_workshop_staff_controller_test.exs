defmodule DhcWeb.BeginnersWorkshopStaffControllerTest do
  @moduledoc """
  ALE-379 contract tests: `beginnersWorkshops.setStaff`,
  `beginnersWorkshops.staffCandidates`, the `beginnersWorkshopAssignments`
  slice ("My Beginners' Workshops") and the `beginnersWorkshopDoor` slice,
  including the door view's concealment from anyone not on the Staff.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias DhcWeb.OpenApiVerifier

  setup do
    coordinator = staff_fixture("beginners_coordinator", %{first_name: "Cora"})
    coach = staff_fixture("coach", %{first_name: "Aoife", last_name: "Coach"})
    assistant = staff_fixture("member", %{first_name: "Brian", last_name: "Assist"})
    outsider_coach = staff_fixture("coach", %{first_name: "Dara"})
    outsider = staff_fixture("member", %{first_name: "Eve"})

    people = %{
      "coordinator" => {coordinator, ~w(member beginners_coordinator)},
      "president" => {staff_fixture("president"), ~w(member president)},
      "coach" => {coach, ~w(member coach)},
      "assistant" => {assistant, ~w(member)},
      "outsider_coach" => {outsider_coach, ~w(member coach)},
      "outsider" => {outsider, ~w(member)},
      "treasurer" => {staff_fixture("treasurer"), ~w(member treasurer)}
    }

    tokens =
      Map.new(people, fn {name, {id, roles}} ->
        {"#{name}-session", %{sub: id, email: "#{name}@example.com", roles: roles}}
      end)

    original = OpenApiVerifier.install(tokens: tokens)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    # Far enough ahead that the wall clock the HTTP path uses never reaches it.
    date = Date.add(Date.utc_today(), 30)

    workshop =
      scheduled_fixture(coordinator, %{"date" => Date.to_iso8601(date)},
        clock: Dhc.BeginnersWorkshops.Clock.system()
      )

    %{
      ids: Map.new(people, fn {name, {id, _roles}} -> {name, id} end),
      workshop: workshop
    }
  end

  defp as(conn, name),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{name}-session")

  defp put_staff(conn, name, workshop_id, body),
    do: conn |> as(name) |> put("/api/beginners-workshops/#{workshop_id}/staff", body)

  describe "PUT /beginners-workshops/{id}/staff" do
    test "assigns a coach and assistants and returns the workshop", %{conn: conn} = ctx do
      assert %{
               "data" => %{
                 "id" => id,
                 "alerts" => [],
                 "staff" => %{
                   "coach" => %{"principalId" => coach, "name" => "Aoife Coach"},
                   "assistants" => [%{"principalId" => assistant, "name" => "Brian Assist"}]
                 }
               }
             } =
               conn
               |> put_staff("coordinator", ctx.workshop.id, %{
                 "coachPrincipalId" => ctx.ids["coach"],
                 "assistantPrincipalIds" => [ctx.ids["assistant"], ctx.ids["coach"]]
               })
               |> json_response(200)

      assert {id, coach, assistant} ==
               {ctx.workshop.id, ctx.ids["coach"], ctx.ids["assistant"]}

      # An empty body clears the Staff: Unstaffed again.
      assert %{"data" => %{"alerts" => ["unstaffed"], "staff" => %{"coach" => nil}}} =
               conn |> put_staff("coordinator", ctx.workshop.id, %{}) |> json_response(200)
    end

    test "maps every refusal to its code and field", %{conn: conn} = ctx do
      assert %{
               "errors" => %{
                 "code" => "not_a_coach",
                 "fields" => %{"coachPrincipalId" => [_]}
               }
             } =
               conn
               |> put_staff("coordinator", ctx.workshop.id, %{
                 "coachPrincipalId" => ctx.ids["outsider"]
               })
               |> json_response(422)

      assert %{
               "errors" => %{
                 "code" => "not_a_member",
                 "fields" => %{"assistantPrincipalIds" => [_]}
               }
             } =
               conn
               |> put_staff("coordinator", ctx.workshop.id, %{
                 "assistantPrincipalIds" => [Ecto.UUID.generate()]
               })
               |> json_response(422)

      assert %{"errors" => %{"code" => "invalid_staff"}} =
               conn
               |> put_staff("coordinator", ctx.workshop.id, %{"coachPrincipalId" => "nope"})
               |> json_response(422)

      assert conn
             |> put_staff("coordinator", Ecto.UUID.generate(), %{})
             |> json_response(404)

      force_status!(ctx.workshop.id, "finalised")

      assert %{"errors" => %{"code" => "after_finalisation"}} =
               conn |> put_staff("coordinator", ctx.workshop.id, %{}) |> json_response(409)
    end

    test "only the managers may set Staff; assigned Staff may not", %{conn: conn} = ctx do
      _ =
        put_staff(conn, "coordinator", ctx.workshop.id, %{"coachPrincipalId" => ctx.ids["coach"]})

      for name <- ~w(coach assistant treasurer outsider) do
        assert conn |> put_staff(name, ctx.workshop.id, %{}) |> json_response(403)
      end

      assert conn
             |> put("/api/beginners-workshops/#{ctx.workshop.id}/staff", %{})
             |> json_response(401)
    end
  end

  describe "GET /beginners-workshops/staff-candidates" do
    test "lists active Members with coaches marked, for managers only", %{conn: conn} = ctx do
      assert %{"data" => candidates} =
               conn
               |> as("coordinator")
               |> get("/api/beginners-workshops/staff-candidates")
               |> json_response(200)

      by_id = Map.new(candidates, &{&1["principalId"], &1})
      assert %{"name" => "Aoife Coach", "coach" => true} = by_id[ctx.ids["coach"]]
      assert %{"coach" => false} = by_id[ctx.ids["assistant"]]

      assert conn
             |> as("coach")
             |> get("/api/beginners-workshops/staff-candidates")
             |> json_response(403)
    end
  end

  describe "GET /beginners-workshops/mine" do
    test "lists the caller's own assignments with their role", %{conn: conn} = ctx do
      _ =
        put_staff(conn, "coordinator", ctx.workshop.id, %{
          "coachPrincipalId" => ctx.ids["coach"],
          "assistantPrincipalIds" => [ctx.ids["assistant"]]
        })

      assert %{"data" => [%{"id" => id, "role" => "coach", "startTime" => "18:30"} = row]} =
               conn |> as("coach") |> get("/api/beginners-workshops/mine") |> json_response(200)

      assert id == ctx.workshop.id

      assert Map.keys(row) |> Enum.sort() ==
               ~w(date id role stage startTime status venue)

      assert %{"data" => [%{"role" => "assistant"}]} =
               conn
               |> as("assistant")
               |> get("/api/beginners-workshops/mine")
               |> json_response(200)

      for name <- ~w(outsider coordinator) do
        assert %{"data" => []} =
                 conn |> as(name) |> get("/api/beginners-workshops/mine") |> json_response(200)
      end

      assert conn |> get("/api/beginners-workshops/mine") |> json_response(401)
    end
  end

  describe "GET /beginners-workshops/{id}/door" do
    setup %{conn: conn} = ctx do
      _ =
        put_staff(conn, "coordinator", ctx.workshop.id, %{
          "coachPrincipalId" => ctx.ids["coach"],
          "assistantPrincipalIds" => [ctx.ids["assistant"]]
        })

      %{path: "/api/beginners-workshops/#{ctx.workshop.id}/door"}
    end

    test "assigned Staff and managers see the header", %{conn: conn, path: path} = ctx do
      for name <- ~w(coach assistant coordinator president) do
        assert %{"data" => data} = conn |> as(name) |> get(path) |> json_response(200)

        assert Map.keys(data) |> Enum.sort() ==
                 ~w(alerts checkIn date finalisation id people staff stage startTime status venue)

        assert %{"id" => id, "staff" => %{"coach" => %{"name" => "Aoife Coach"}}} = data
        assert id == ctx.workshop.id
      end
    end

    test "anyone else gets the same 404 as an unknown workshop", %{conn: conn, path: path} do
      unknown =
        conn
        |> as("outsider")
        |> get("/api/beginners-workshops/#{Ecto.UUID.generate()}/door")
        |> json_response(404)

      for name <- ~w(outsider outsider_coach treasurer) do
        assert conn |> as(name) |> get(path) |> json_response(404) == unknown
      end

      assert conn
             |> as("coach")
             |> get("/api/beginners-workshops/not-a-uuid/door")
             |> json_response(404) == unknown

      assert conn |> get(path) |> json_response(401)
    end

    test "access follows the Staff immediately", %{conn: conn, path: path} = ctx do
      assert conn |> as("assistant") |> get(path) |> json_response(200)

      _ =
        put_staff(conn, "coordinator", ctx.workshop.id, %{
          "coachPrincipalId" => ctx.ids["coach"]
        })

      assert conn |> as("assistant") |> get(path) |> json_response(404)
    end
  end

  describe "POST /beginners-workshops with optional Staff" do
    test "schedules with Staff and names a refused coach by index", %{conn: conn} = ctx do
      item = %{
        "venue" => "St. Andrew's Hall",
        "date" => Date.to_iso8601(Date.add(Date.utc_today(), 40)),
        "startTime" => "18:30",
        "capacity" => 16,
        "feeCents" => 4000
      }

      assert %{"data" => [%{"alerts" => [], "staff" => %{"coach" => %{"principalId" => coach}}}]} =
               conn
               |> as("coordinator")
               |> post("/api/beginners-workshops", %{
                 "workshops" => [Map.put(item, "coachPrincipalId", ctx.ids["coach"])]
               })
               |> json_response(201)

      assert coach == ctx.ids["coach"]

      assert %{
               "errors" => %{
                 "code" => "not_a_coach",
                 "fields" => %{"workshops.0.coachPrincipalId" => [_]}
               }
             } =
               conn
               |> as("coordinator")
               |> post("/api/beginners-workshops", %{
                 "workshops" => [Map.put(item, "coachPrincipalId", ctx.ids["outsider"])]
               })
               |> json_response(422)
    end
  end
end
