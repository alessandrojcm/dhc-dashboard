defmodule DhcWeb.BeginnersWorkshopsControllerTest do
  @moduledoc """
  ALE-378 contract test for the `beginnersWorkshops` slice: the capability
  gate, success shapes, and the problem `code`/`fields` of every refusal.
  """
  use DhcWeb.ConnCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP
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
        "endTime" => "20:30",
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
    contact_from = Date.add(Date.utc_today(), -1)

    [first, second] =
      schedule!(conn, [
        item(%{
          "date" => Date.to_iso8601(Date.add(date, 7)),
          "contactFromDate" => Date.to_iso8601(contact_from)
        }),
        item(%{"paymentWindowDays" => 3, "paymentCutoffTime" => "12:00"})
      ])

    assert %{
             "status" => "scheduled",
             "venue" => "St. Andrew's Hall",
             "startTime" => "18:30",
             "endTime" => "20:30",
             "capacity" => 16,
             "feeCents" => 4000,
             "paymentCutoffDate" => cutoff_date,
             "paymentCutoffTime" => "18:30",
             "paymentCutoff" => _instant,
             "contactFromDate" => contact_from_date,
             "contactFromEditable" => true,
             "paymentWindowDays" => 7,
             "stage" => "next_batch_due",
             "seats" => %{"capacity" => 16, "paid" => 0, "holds" => 0, "free" => 16},
             "alerts" => ["unstaffed"]
           } = first

    assert cutoff_date == Date.to_iso8601(Date.add(date, 4))
    assert contact_from_date == Date.to_iso8601(contact_from)
    assert %{"paymentWindowDays" => 3, "paymentCutoffTime" => "12:00"} = second

    assert %{"data" => %{"upcoming" => upcoming, "past" => []}} =
             conn |> as_role("president") |> get("/api/beginners-workshops") |> json_response(200)

    assert Enum.map(upcoming, & &1["id"]) == [second["id"], first["id"]]
  end

  test "a refused workshop is named by its index in the fields", %{conn: conn} do
    assert %{
             "errors" => %{
               "code" => "invalid_contact_from",
               "detail" => "Offers must start on or before the payment deadline",
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

    assert %{
             "errors" => %{
               "code" => "invalid_workshop",
               "fields" => %{"workshops.0.endTime" => [_]}
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops", %{"workshops" => [Map.delete(item(), "endTime")]})
             |> json_response(422)

    for end_time <- ["18:30", "18:29"] do
      assert %{
               "errors" => %{
                 "code" => "invalid_end_time",
                 "fields" => %{"workshops.0.endTime" => [_]}
               }
             } =
               conn
               |> as_role("beginners_coordinator")
               |> post("/api/beginners-workshops", %{
                 "workshops" => [item(%{"endTime" => end_time})]
               })
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

  test "reschedules a workshop and maps every refusal", %{conn: conn} do
    [workshop] = schedule!(conn)
    path = "/api/beginners-workshops/#{workshop["id"]}/reschedule"
    coordinator = as_role(conn, "beginners_coordinator")
    date = Date.add(Date.from_iso8601!(workshop["date"]), 7)

    assert %{
             "data" => %{
               "date" => new_date,
               "startTime" => "19:00",
               "endTime" => "21:00",
               "venue" => "The Hub",
               "paymentCutoffDate" => cutoff_date,
               "paymentCutoffTime" => "19:00"
             }
           } =
             coordinator
             |> post(path, %{
               "date" => Date.to_iso8601(date),
               "startTime" => "19:00",
               "endTime" => "21:00",
               "venue" => "The Hub"
             })
             |> json_response(200)

    assert new_date == Date.to_iso8601(date)
    # The cutoff kept its 3 days before the start.
    assert cutoff_date == date |> Date.add(-3) |> Date.to_iso8601()

    assert %{"errors" => %{"fields" => %{"date" => [_]}} = errors} =
             coordinator
             |> post(path, %{"venue" => "The Hub", "startTime" => "19:00", "endTime" => "21:00"})
             |> json_response(422)

    refute Map.has_key?(errors, "code")

    assert %{
             "errors" => %{
               "fields" => %{"startTime" => [_], "endTime" => [_]}
             }
           } = coordinator |> post(path, %{"venue" => "Elsewhere"}) |> json_response(422)

    assert %{
             "errors" => %{
               "code" => "invalid_payment_cutoff",
               "fields" => %{"paymentCutoffDate" => [_]}
             }
           } =
             coordinator
             |> post(path, %{
               "venue" => "St. Andrew's Hall",
               "startTime" => "19:00",
               "endTime" => "21:00",
               "paymentCutoffDate" => Date.to_iso8601(Date.add(date, 1))
             })
             |> json_response(422)

    assert coordinator
           |> post("/api/beginners-workshops/#{Ecto.UUID.generate()}/reschedule", %{
             "venue" => "Elsewhere"
           })
           |> json_response(404)

    assert conn
           |> as_role("treasurer")
           |> post(path, %{"venue" => "Elsewhere"})
           |> json_response(403)

    BeginnersWorkshopFixtures.force_status!(workshop["id"], "cancelled")

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator |> post(path, %{"venue" => "Elsewhere"}) |> json_response(409)

    BeginnersWorkshopFixtures.force_status!(workshop["id"], "finalised")

    assert %{"errors" => %{"code" => "after_finalisation"}} =
             coordinator |> post(path, %{"venue" => "Elsewhere"}) |> json_response(409)
  end

  test "schedules and reschedules with destination details, mapping field errors (ALE-441)", %{
    conn: conn
  } do
    destination = %{
      "destinationText" => "National Basketball Arena, Tymon Park, Dublin 6w"
    }

    [with_destination, label_only] = schedule!(conn, [item(destination), item()])
    assert Map.take(with_destination, Map.keys(destination)) == destination

    assert Map.take(label_only, Map.keys(destination)) == %{
             "destinationText" => nil
           }

    coordinator = as_role(conn, "beginners_coordinator")

    assert %{
             "errors" => %{
               "fields" => %{
                 "workshops.1.destinationText" => [_]
               }
             }
           } =
             coordinator
             |> post("/api/beginners-workshops", %{
               "workshops" => [item(), item(%{"destinationText" => String.duplicate("a", 501)})]
             })
             |> json_response(422)

    date = Date.add(Date.from_iso8601!(label_only["date"]), 7) |> Date.to_iso8601()

    assert %{"data" => %{"venue" => "The Hub", "destinationText" => "The Hub, upstairs"}} =
             coordinator
             |> post("/api/beginners-workshops/#{label_only["id"]}/reschedule", %{
               "date" => date,
               "startTime" => "18:30",
               "endTime" => "20:30",
               "venue" => "The Hub",
               "destinationText" => "The Hub, upstairs"
             })
             |> json_response(200)
  end

  test "a selected Google place round-trips through schedule, update and clear (ALE-442)", %{
    conn: conn
  } do
    selected = %{"destinationText" => nil, "destinationPlaceId" => "place_hall"}

    [first, second] = schedule!(conn, [item(selected), item(selected)])

    for workshop <- [first, second] do
      assert %{
               "destinationProvider" => "google",
               "destinationPlaceId" => "place_hall",
               "destinationText" => nil
             } = workshop

      refute Map.has_key?(workshop, "destinationAttributions")
    end

    coordinator = as_role(conn, "beginners_coordinator")
    path = "/api/beginners-workshops/#{first["id"]}/destination"

    assert %{"data" => manual} =
             coordinator
             |> put(path, %{
               "venue" => first["venue"],
               "destinationText" => "Our Own Hall",
               "destinationPlaceId" => nil
             })
             |> json_response(200)

    assert %{
             "destinationText" => "Our Own Hall",
             "destinationProvider" => nil,
             "destinationPlaceId" => nil
           } = manual

    assert %{"errors" => %{"fields" => %{"destinationPlaceId" => ["is not a valid place"]}}} =
             coordinator
             |> put(
               path,
               Map.merge(selected, %{"venue" => first["venue"], "destinationPlaceId" => "x/y"})
             )
             |> json_response(422)

    # The other date keeps its own copy of the selection.
    assert %{"data" => %{"workshop" => %{"destinationPlaceId" => "place_hall"}}} =
             coordinator
             |> get("/api/beginners-workshops/#{second["id"]}/console")
             |> json_response(200)
  end

  test "updates only the destination and maps every refusal (ALE-441)", %{conn: conn} do
    [workshop] = schedule!(conn)
    path = "/api/beginners-workshops/#{workshop["id"]}/destination"
    coordinator = as_role(conn, "beginners_coordinator")

    body = %{
      "venue" => workshop["venue"],
      "destinationText" => "National Basketball Arena, Tymon Park, Dublin 6w"
    }

    assert %{"data" => updated} = coordinator |> put(path, body) |> json_response(200)
    assert updated["destinationText"] == "National Basketball Arena, Tymon Park, Dublin 6w"

    assert Map.drop(updated, ~w(destinationText)) == Map.drop(workshop, ~w(destinationText))

    # An omitted key keeps its value; `null` clears it.
    assert %{"data" => %{"destinationText" => "National Basketball Arena, Tymon Park, Dublin 6w"}} =
             coordinator
             |> put(path, %{"venue" => workshop["venue"]})
             |> json_response(200)

    message = "Choose a suggested place or type the destination, not both"

    assert %{
             "errors" => %{"fields" => %{"destinationText" => [^message]}} = errors
           } =
             coordinator
             |> put(path, Map.put(body, "destinationPlaceId", "place_hall"))
             |> json_response(422)

    refute Map.has_key?(errors, "code")

    assert %{"errors" => %{"code" => "venue_changed", "fields" => %{"venue" => [_]}}} =
             coordinator |> put(path, Map.put(body, "venue", "Elsewhere")) |> json_response(409)

    assert %{"errors" => %{"fields" => %{"venue" => [_]}}} =
             coordinator |> put(path, Map.delete(body, "venue")) |> json_response(422)

    assert coordinator
           |> put("/api/beginners-workshops/#{Ecto.UUID.generate()}/destination", body)
           |> json_response(404)

    assert conn |> as_role("treasurer") |> put(path, body) |> json_response(403)

    BeginnersWorkshopFixtures.force_status!(workshop["id"], "cancelled")

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator |> put(path, body) |> json_response(409)
  end

  test "cancels a workshop and maps every refusal (ALE-395)", %{conn: conn} do
    [workshop] = schedule!(conn)
    path = "/api/beginners-workshops/#{workshop["id"]}/cancel"
    coordinator = as_role(conn, "beginners_coordinator")

    assert conn |> as_role("treasurer") |> post(path, %{}) |> json_response(403)

    assert %{"errors" => %{"code" => "invalid_reason", "fields" => %{"reason" => [_]}}} =
             coordinator
             |> post(path, %{"reason" => String.duplicate("x", 501)})
             |> json_response(422)

    assert coordinator
           |> post("/api/beginners-workshops/#{Ecto.UUID.generate()}/cancel", %{})
           |> json_response(404)

    assert %{
             "data" => %{
               "workshop" => %{"status" => "cancelled", "stage" => "cancelled"},
               "deferred" => 0,
               "returned" => 0,
               "released" => 0
             }
           } = coordinator |> post(path, %{"reason" => "Hall flooded"}) |> json_response(200)

    assert %{
             "data" => %{
               "cancelPreview" => nil,
               "cancellation" => %{"at" => _, "by" => _, "reason" => "Hall flooded"}
             }
           } =
             coordinator
             |> get("/api/beginners-workshops/#{workshop["id"]}/console")
             |> json_response(200)

    assert %{"errors" => %{"code" => "already_cancelled"}} =
             coordinator |> post(path, %{}) |> json_response(409)
  end

  test "schedule, reschedule and cancel reconcile one Calendar event only after the worker runs",
       %{
         conn: conn
       } do
    server = calendar_surface!()
    original = item()
    [scheduled] = schedule!(conn, [original])
    args = %{"source_kind" => "beginners_workshop", "source_id" => scheduled["id"]}

    assert_enqueued(worker: SyncWorker, args: args)
    assert WorkshopCalendarHTTP.requests(server) == []
    assert :ok = perform_job(SyncWorker, args)

    assert [created] = Map.values(WorkshopCalendarHTTP.events(server))
    assert created["summary"] == "Beginners' Workshop"
    assert created["description"] =~ "/dashboard/beginners-workshop/workshops/#{scheduled["id"]}"
    assert_event_times(created, original["date"], original["startTime"], original["endTime"])

    rescheduled_date = Date.add(Date.from_iso8601!(original["date"]), 7) |> Date.to_iso8601()
    mutation_count = length(WorkshopCalendarHTTP.mutations(server))

    assert %{"data" => %{"date" => ^rescheduled_date}} =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops/#{scheduled["id"]}/reschedule", %{
               "date" => rescheduled_date,
               "startTime" => "19:00",
               "endTime" => "21:00",
               "venue" => "The Hub"
             })
             |> json_response(200)

    assert length(WorkshopCalendarHTTP.mutations(server)) == mutation_count
    assert :ok = perform_job(SyncWorker, args)

    assert [rescheduled] = Map.values(WorkshopCalendarHTTP.events(server))
    assert rescheduled["id"] == created["id"]
    assert rescheduled["location"] == "The Hub"
    assert_event_times(rescheduled, rescheduled_date, "19:00", "21:00")

    mutation_count = length(WorkshopCalendarHTTP.mutations(server))

    assert %{"data" => %{"workshop" => %{"status" => "cancelled"}}} =
             conn
             |> as_role("beginners_coordinator")
             |> post("/api/beginners-workshops/#{scheduled["id"]}/cancel", %{})
             |> json_response(200)

    assert length(WorkshopCalendarHTTP.mutations(server)) == mutation_count
    assert :ok = perform_job(SyncWorker, args)

    assert [cancelled] = Map.values(WorkshopCalendarHTTP.events(server))
    assert cancelled["id"] == created["id"]
    assert cancelled["summary"] == "[Cancelled] Beginners' Workshop"
    assert_event_times(cancelled, rescheduled_date, "19:00", "21:00")
  end

  test "the console previews what Cancel would do while scheduled", %{conn: conn} do
    [workshop] = schedule!(conn)

    assert %{
             "data" => %{
               "cancelPreview" => %{"deferred" => 0, "returned" => 0, "released" => 0},
               "cancellation" => nil
             }
           } =
             conn
             |> as_role("beginners_coordinator")
             |> get("/api/beginners-workshops/#{workshop["id"]}/console")
             |> json_response(200)
  end

  defp calendar_surface! do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "calendar-client",
      client_secret: "calendar-secret",
      refresh_token: "calendar-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server)
    server
  end

  defp assert_event_times(event, date, start_time, end_time) do
    date = Date.from_iso8601!(date)
    start_time = Time.from_iso8601!(start_time <> ":00")
    end_time = Time.from_iso8601!(end_time <> ":00")

    assert event["start"]["dateTime"] ==
             date |> ClubCalendar.to_utc(start_time) |> DateTime.to_iso8601()

    assert event["end"]["dateTime"] ==
             date |> ClubCalendar.to_utc(end_time) |> DateTime.to_iso8601()
  end
end
