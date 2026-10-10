defmodule DhcWeb.BeginnersWorkshopDoorControllerTest do
  @moduledoc """
  ALE-390 contract tests for the `beginnersWorkshopDoor` slice's door list
  and check-in: `GET /door` carries the door list in its own closed shape,
  `POST`/`DELETE /door/people/{intakeId}/check-in` record and undo a
  check-in, `POST /door/finish` (ALE-391) finalises attendance, and anyone
  not on the Staff gets the same 404 as an unknown workshop.
  """
  use DhcWeb.ConnCase, async: false

  import Dhc.BeginnersWorkshopFixtures

  alias DhcWeb.OpenApiVerifier

  setup do
    coordinator = staff_fixture("beginners_coordinator", %{first_name: "Cora"})
    coach = staff_fixture("coach", %{first_name: "Aoife", last_name: "Coach"})
    outsider = staff_fixture("member", %{first_name: "Eve"})

    people = %{
      "coordinator" => {coordinator, ~w(member beginners_coordinator)},
      "coach" => {coach, ~w(member coach)},
      "outsider" => {outsider, ~w(member)}
    }

    tokens =
      Map.new(people, fn {name, {id, roles}} ->
        {"#{name}-session", %{sub: id, email: "#{name}@example.com", roles: roles}}
      end)

    original = OpenApiVerifier.install(tokens: tokens)
    on_exit(fn -> OpenApiVerifier.restore(original) end)

    workshop = scheduled_fixture(coordinator)
    set_staff!(workshop.id, coach)

    minor =
      paid_person_fixture!(workshop.id,
        first_name: "Ciara",
        date_of_birth: Date.add(Date.utc_today(), -17 * 365),
        medical_conditions: "Asthma",
        guardian: {"Gráinne", "Parent", "+353870000001"}
      )

    # The HTTP path reads the wall clock: the workshop starts this minute.
    force_today!(workshop.id)

    %{
      workshop: workshop,
      minor: minor,
      door: "/api/beginners-workshops/#{workshop.id}/door",
      check_in: "/api/beginners-workshops/#{workshop.id}/door/people/#{minor.id}/check-in",
      finish: "/api/beginners-workshops/#{workshop.id}/door/finish"
    }
  end

  defp as(conn, name),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{name}-session")

  test "GET /door carries the door list in its own shape", %{conn: conn} = ctx do
    assert %{"data" => data} = conn |> as("coach") |> get(ctx.door) |> json_response(200)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(alerts checkIn date finalisation id people staff stage startTime status venue)

    assert %{"stage" => "check_in_open", "checkIn" => %{"window" => "open", "opensAt" => _}} =
             data

    assert [person] = data["people"]

    assert Map.keys(person) |> Enum.sort() ==
             ~w(checkedIn firstName guardian id lastName medicalConditions minor pronouns state)

    assert %{
             "firstName" => "Ciara",
             "minor" => true,
             "medicalConditions" => "Asthma",
             "guardian" => %{"name" => "Gráinne Parent", "phoneNumber" => "+353870000001"},
             "checkedIn" => nil,
             "state" => "paid"
           } = person
  end

  test "POST check-in records who and when; DELETE undoes it", %{conn: conn} = ctx do
    assert %{"data" => %{"people" => [%{"checkedIn" => %{"by" => "Aoife Coach", "at" => at}}]}} =
             conn |> as("coach") |> post(ctx.check_in) |> json_response(200)

    assert {:ok, _at, 0} = DateTime.from_iso8601(at)

    assert %{"data" => %{"people" => [%{"checkedIn" => nil}]}} =
             conn |> as("coordinator") |> delete(ctx.check_in) |> json_response(200)
  end

  test "an unpaid person is a 409 with its code", %{conn: conn} = ctx do
    {contacted, _token} =
      intake_fixture!(ctx.workshop.id, waiting_person_fixture(~U[2025-02-01 12:00:00Z]))

    assert %{"errors" => %{"code" => "not_paid", "detail" => _}} =
             conn
             |> as("coach")
             |> post(
               "/api/beginners-workshops/#{ctx.workshop.id}/door/people/#{contacted.id}/check-in"
             )
             |> json_response(409)
  end

  test "outside the window is a 409", %{conn: conn} = ctx do
    force_status!(ctx.workshop.id, "finalised")

    assert %{"errors" => %{"code" => "check_in_closed"}} =
             conn |> as("coach") |> post(ctx.check_in) |> json_response(409)
  end

  test "POST finish finalises attendance and answers the finalised summary",
       %{conn: conn} = ctx do
    assert %{"data" => data} = conn |> as("coach") |> post(ctx.finish) |> json_response(200)

    assert %{
             "status" => "finalised",
             "stage" => "finalised",
             "checkIn" => %{"window" => "closed"},
             "people" => [%{"state" => "no_show", "checkedIn" => nil}],
             "finalisation" => %{"by" => "Aoife Coach", "attended" => 0, "noShow" => 1, "at" => _}
           } = data

    assert %{"errors" => %{"code" => "after_finalisation"}} =
             conn |> as("coach") |> post(ctx.finish) |> json_response(409)

    assert conn |> as("outsider") |> post(ctx.finish) |> json_response(404)
  end

  test "anyone not on the Staff gets the same 404 as an unknown workshop", %{conn: conn} = ctx do
    unknown =
      conn
      |> as("coach")
      |> post(
        "/api/beginners-workshops/#{Ecto.UUID.generate()}/door/people/#{ctx.minor.id}/check-in"
      )
      |> json_response(404)

    assert conn |> as("outsider") |> post(ctx.check_in) |> json_response(404) == unknown
    assert conn |> as("outsider") |> delete(ctx.check_in) |> json_response(404) == unknown
    assert conn |> as("outsider") |> get(ctx.door) |> json_response(404) == unknown

    assert conn
           |> as("coach")
           |> post("/api/beginners-workshops/#{ctx.workshop.id}/door/people/nope/check-in")
           |> json_response(404) == unknown

    assert conn |> post(ctx.check_in) |> json_response(401)
    assert Dhc.Repo.get!(Dhc.BeginnersWorkshops.Intake, ctx.minor.id).checked_in_at == nil
  end
end
