defmodule DhcWeb.BeginnersWorkshopBatchesControllerTest do
  @moduledoc """
  ALE-380 contract test for the console read (`beginnersWorkshops.console`)
  and the `beginnersWorkshopBatches` slice: the capability gate, the console
  shape after an automatic Batch, pause/resume, and the `fee_locked` refusal.
  """
  use DhcWeb.ConnCase, async: false

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.Clock
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator president workshop_coordinator coach member)

  setup %{conn: conn} do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    # Far enough ahead that the wall clock the HTTP path uses never reaches
    # the contact-from date.
    contact_from = Date.add(ClubCalendar.today(), 30)

    %{"data" => [workshop]} =
      conn
      |> as_role("beginners_coordinator")
      |> post("/api/beginners-workshops", %{
        "workshops" => [
          %{
            "venue" => "St. Andrew's Hall",
            "date" => Date.to_iso8601(Date.add(contact_from, 30)),
            "startTime" => "18:30",
            "capacity" => 2,
            "feeCents" => 4000,
            "contactFromDate" => Date.to_iso8601(contact_from)
          }
        ]
      })
      |> json_response(201)

    %{workshop: workshop, contact_from: contact_from}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp send_batch!(%{workshop: workshop, contact_from: contact_from}) do
    at = ClubCalendar.to_utc(contact_from, ~T[10:00:00])

    {:ok, %{outcome: :sent}} =
      BeginnersWorkshops.execute(:system, {:send_due_batch, workshop["id"]},
        clock: Clock.fixed(at)
      )
  end

  test "only managers reach the console and the pause commands", %{conn: conn, workshop: w} do
    console = "/api/beginners-workshops/#{w["id"]}/console"
    pause = "/api/beginners-workshops/#{w["id"]}/batches/pause"

    assert conn |> get(console) |> json_response(401)
    assert conn |> post(pause) |> json_response(401)

    for role <- ~w(workshop_coordinator coach member) do
      assert conn |> as_role(role) |> get(console) |> json_response(403)
      assert conn |> as_role(role) |> post(pause) |> json_response(403)
    end

    assert conn |> as_role("president") |> get(console) |> json_response(200)

    assert conn
           |> as_role("beginners_coordinator")
           |> get("/api/beginners-workshops/#{Ecto.UUID.generate()}/console")
           |> json_response(404)
  end

  test "the console shows the Next Batch preview before Batch 1", %{conn: conn, workshop: w} do
    BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z],
      first_name: "Aoife"
    )

    BeginnersWorkshopFixtures.waiting_person_fixture(~U[2025-02-01 12:00:00Z],
      first_name: "Bea",
      date_of_birth: Date.add(ClubCalendar.today(), -365 * 17)
    )

    assert %{
             "data" => %{
               "workshop" => %{"stage" => "before_contact_from"},
               "batches" => [],
               "pause" => %{"paused" => false, "pausedBy" => nil},
               "nextBatch" => %{
                 "status" => "scheduled",
                 "goesOutAt" => goes_out_at,
                 "number" => 1,
                 "size" => 2,
                 "capacity" => 2,
                 "paid" => 0,
                 "people" => [
                   %{"firstName" => "Aoife", "minor" => false},
                   %{"firstName" => "Bea", "minor" => true}
                 ]
               },
               "roster" => %{"seated" => [], "asked" => [], "out" => []},
               "attention" => []
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/#{w["id"]}/console")
             |> json_response(200)

    assert is_binary(goes_out_at)
  end

  test "after a Batch the console lists it and the people asked, not paid yet",
       %{conn: conn, workshop: w} = ctx do
    BeginnersWorkshopFixtures.waiting_people_fixture(3)
    send_batch!(ctx)

    assert %{
             "data" => %{
               "workshop" => %{"stage" => "window_open", "contactFromEditable" => false},
               "batches" => [%{"number" => 1, "size" => 2}],
               "nextBatch" => %{"number" => 2, "status" => "scheduled"},
               "roster" => %{"asked" => [asked, _], "seated" => []}
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/#{w["id"]}/console")
             |> json_response(200)

    assert %{"state" => "contacted", "origin" => "batch", "batchNumber" => 1} = asked
  end

  test "pause and resume answer with the workshop", %{conn: conn, workshop: w} do
    coordinator = as_role(conn, "beginners_coordinator")

    for _ <- 1..2 do
      assert %{"data" => %{"stage" => "batches_paused"}} =
               coordinator
               |> post("/api/beginners-workshops/#{w["id"]}/batches/pause")
               |> json_response(200)
    end

    assert %{"data" => %{"pause" => %{"paused" => true, "pausedBy" => "Test Member"}}} =
             coordinator
             |> get("/api/beginners-workshops/#{w["id"]}/console")
             |> json_response(200)

    assert %{"data" => %{"stage" => "before_contact_from"}} =
             coordinator
             |> post("/api/beginners-workshops/#{w["id"]}/batches/resume")
             |> json_response(200)

    assert coordinator
           |> post("/api/beginners-workshops/#{Ecto.UUID.generate()}/batches/pause")
           |> json_response(404)

    BeginnersWorkshopFixtures.force_status!(w["id"], "cancelled")

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator
             |> post("/api/beginners-workshops/#{w["id"]}/batches/resume")
             |> json_response(409)
  end

  test "a fee change is refused once an Intake exists", %{conn: conn, workshop: w} = ctx do
    BeginnersWorkshopFixtures.waiting_people_fixture(1)
    send_batch!(ctx)

    assert %{
             "errors" => %{
               "code" => "fee_locked",
               "fields" => %{"feeCents" => [_]}
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> put("/api/beginners-workshops/#{w["id"]}/settings", %{"feeCents" => 4500})
             |> json_response(409)
  end
end
