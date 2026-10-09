defmodule DhcWeb.BeginnersWorkshopsControllerTest do
  @moduledoc """
  ALE-378 contract test for the `beginnersWorkshops` slice: the capability
  gate, success shapes, and the problem `code`/`fields` of every refusal.
  """
  use DhcWeb.ConnCase, async: false

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.Repo
  alias DhcWeb.OpenApiVerifier

  @roles ~w(beginners_coordinator president admin committee_coordinator workshop_coordinator treasurer coach member)
  @managers ~w(beginners_coordinator president admin committee_coordinator)

  setup do
    role_subs =
      Map.new(@roles, fn role ->
        member = Dhc.MemberFixtures.member_fixture()

        if role != "member",
          do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

        {role, member.principal_id}
      end)

    original = OpenApiVerifier.install(roles: @roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    %{role_subs: role_subs}
  end

  defp as_role(conn, role),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{role}-token")

  # Far enough ahead that the wall clock the HTTP path uses never reaches it.
  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        "venue" => "St. Andrew's Hall",
        "date" => Date.to_iso8601(Date.add(Date.utc_today(), 60)),
        "startTime" => "18:30",
        "capacity" => 16,
        "feeCents" => 4000
      },
      overrides
    )
  end

  defp schedule!(conn, items \\ [item()]) do
    %{"data" => views} =
      conn
      |> as_role("beginners_coordinator")
      |> post("/api/beginners-workshops", %{"workshops" => items})
      |> json_response(201)

    views
  end

  test "only the beginners coordinator and the officers reach the slice", %{conn: conn} do
    assert conn |> get("/api/beginners-workshops") |> json_response(401)

    for role <- @roles -- @managers do
      assert %{"errors" => %{"detail" => _} = errors} =
               conn |> as_role(role) |> get("/api/beginners-workshops") |> json_response(403)

      refute Map.has_key?(errors, "code")

      assert conn
             |> as_role(role)
             |> post("/api/beginners-workshops", %{"workshops" => [item()]})
             |> json_response(403)
    end

    for role <- @managers do
      assert %{"data" => %{"upcoming" => [], "past" => []}} =
               conn |> as_role(role) |> get("/api/beginners-workshops") |> json_response(200)
    end
  end

  test "schedules several workshops and lists them with stage, seats and alerts", %{conn: conn} do
    date = Date.add(Date.utc_today(), 60)

    [first, second] =
      schedule!(conn, [
        item(%{"date" => Date.to_iso8601(Date.add(date, 7))}),
        item(%{"paymentWindowDays" => 3, "paymentCutoffTime" => "12:00"})
      ])

    assert %{
             "status" => "scheduled",
             "venue" => "St. Andrew's Hall",
             "startTime" => "18:30",
             "capacity" => 16,
             "feeCents" => 4000,
             "paymentCutoffDate" => cutoff_date,
             "paymentCutoffTime" => "18:30",
             "paymentCutoff" => _instant,
             "contactFromDate" => _today,
             "contactFromEditable" => true,
             "paymentWindowDays" => 7,
             "stage" => "next_batch_due",
             "seats" => %{"capacity" => 16, "paid" => 0, "holds" => 0, "free" => 16},
             "alerts" => ["unstaffed"]
           } = first

    assert cutoff_date == Date.to_iso8601(Date.add(date, 4))
    assert %{"paymentWindowDays" => 3, "paymentCutoffTime" => "12:00"} = second

    assert %{"data" => %{"upcoming" => upcoming, "past" => []}} =
             conn |> as_role("president") |> get("/api/beginners-workshops") |> json_response(200)

    assert Enum.map(upcoming, & &1["id"]) == [second["id"], first["id"]]
  end

  test "a refused workshop is named by its index in the fields", %{conn: conn} do
    assert %{
             "errors" => %{
               "code" => "invalid_contact_from",
               "detail" => "The contact-from date must be on or before the cutoff date",
               "fields" => %{"workshops.1.contactFromDate" => [_]}
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops", %{
               "workshops" => [
                 item(),
                 item(%{"contactFromDate" => Date.to_iso8601(Date.add(Date.utc_today(), 59))})
               ]
             })
             |> json_response(422)

    assert %{
             "errors" => %{
               "code" => "invalid_workshop",
               "fields" => %{"workshops.0.venue" => [_]}
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops", %{
               "workshops" => [item(%{"venue" => String.duplicate("v", 81)})]
             })
             |> json_response(422)

    for {body, code} <- [
          {%{"workshops" => []}, "no_workshops"},
          {%{"workshops" => [item(%{"date" => "2020-01-01"})]}, "start_in_past"},
          {%{"workshops" => [item(%{"paymentCutoffDate" => item()["date"]})]},
           "invalid_payment_cutoff"}
        ] do
      assert %{"errors" => %{"code" => ^code}} =
               conn
               |> as_role("beginners_coordinator")
               |> post("/api/beginners-workshops", body)
               |> json_response(422)
    end

    assert %{"errors" => %{"detail" => "workshops must be a list"} = errors} =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops", %{})
             |> json_response(422)

    refute Map.has_key?(errors, "code")
  end

  test "updates settings and maps every refusal", %{conn: conn} do
    [workshop] = schedule!(conn)
    path = "/api/beginners-workshops/#{workshop["id"]}/settings"
    coordinator = as_role(conn, "beginners_coordinator")

    assert %{"data" => %{"capacity" => 20, "paymentWindowDays" => 5, "feeCents" => 4000}} =
             coordinator
             |> put(path, %{"capacity" => 20, "paymentWindowDays" => 5})
             |> json_response(200)

    assert %{
             "errors" => %{
               "code" => "invalid_payment_cutoff",
               "fields" => %{"paymentCutoffDate" => [_]}
             }
           } =
             coordinator
             |> put(path, %{
               "paymentCutoffDate" => workshop["date"],
               "paymentCutoffTime" => "19:00"
             })
             |> json_response(422)

    assert %{"errors" => %{"fields" => %{"capacity" => [_]}} = errors} =
             coordinator |> put(path, %{"capacity" => 0}) |> json_response(422)

    refute Map.has_key?(errors, "code")

    assert coordinator
           |> put("/api/beginners-workshops/#{Ecto.UUID.generate()}/settings", %{"capacity" => 3})
           |> json_response(404)

    assert conn |> as_role("treasurer") |> put(path, %{"capacity" => 30}) |> json_response(403)

    BeginnersWorkshopFixtures.force_status!(workshop["id"], "cancelled")

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator |> put(path, %{"capacity" => 30}) |> json_response(409)

    BeginnersWorkshopFixtures.force_status!(workshop["id"], "finalised")

    assert %{"errors" => %{"code" => "after_finalisation"}} =
             coordinator |> put(path, %{"capacity" => 30}) |> json_response(409)
  end
end
