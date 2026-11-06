defmodule Dhc.WorkshopCalendar.SyncTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  @now ~U[2027-03-01 12:00:00Z]

  setup do
    previous = Application.get_env(:dhc, WorkshopCalendar, [])

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
    :ok
  end

  test "a planned Workshop queues a private committee projection and publication updates its identity" do
    parent = self()

    Req.Test.stub(Google, fn conn ->
      case {conn.host, conn.method} do
        {"oauth2.googleapis.com", "POST"} ->
          Req.Test.json(conn, %{access_token: "calendar-access", token_type: "Bearer"})

        {"www.googleapis.com", "GET"} ->
          if String.ends_with?(conn.request_path, "/events"),
            do: Req.Test.json(conn, %{kind: "calendar#events"}),
            else: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})

        {"www.googleapis.com", "POST"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          event = Jason.decode!(body)
          send(parent, {:created, event, conn.query_string})
          Req.Test.json(conn, Map.put(event, "etag", "\"first\""))
      end
    end)

    workshop = create_workshop!()
    assert_enqueued(worker: SyncWorker, args: %{source_kind: "workshop", source_id: workshop.id})

    assert :ok = sync(workshop.id)
    assert_receive {:created, event, query}
    assert query == "sendUpdates=none"
    assert event["summary"] == "[Planned] Longsword"
    assert event["location"] == "Club hall"
    assert event["start"]["dateTime"] == "2027-03-28T09:00:00Z"
    assert event["end"]["dateTime"] == "2027-03-28T11:00:00Z"
    assert event["description"] =~ "/dashboard/workshops/#{workshop.id}/attendees"
    refute Jason.encode!(event) =~ "PRIVATE"
    refute Map.has_key?(event, "attendees")

    {:ok, _} = Workshops.publish_workshop(workshop.id)

    Req.Test.stub(Google, fn conn ->
      case {conn.host, conn.method} do
        {"oauth2.googleapis.com", "POST"} ->
          Req.Test.json(conn, %{access_token: "calendar-access", token_type: "Bearer"})

        {"www.googleapis.com", "GET"} ->
          Req.Test.json(conn, Map.put(event, "etag", "\"first\""))

        {"www.googleapis.com", method} when method in ["PUT", "PATCH"] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          updated = Jason.decode!(body)
          assert Plug.Conn.get_req_header(conn, "if-match") == ["\"first\""]
          send(parent, {:updated, updated})
          Req.Test.json(conn, Map.put(updated, "etag", "\"second\""))
      end
    end)

    assert :ok = sync(workshop.id)
    assert_receive {:updated, updated}
    assert updated["summary"] == "Longsword"
    assert updated["id"] == event["id"]
    assert {:error, :not_editable} = Workshops.update_workshop(workshop.id, %{title: "No"})
  end

  test "unchanged reconciliation sends nothing; allowed schedule changes and Google drift repair the same event" do
    server = google_surface!()
    workshop = create_workshop!()
    assert :ok = sync(workshop.id)
    [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert :ok = sync(workshop.id)
    assert [_] = WorkshopCalendarHTTP.mutations(server)

    assert {:ok, _} =
             Workshops.update_workshop(workshop.id, %{title: "Updated", location: "New hall"})

    assert :ok = sync(workshop.id)
    [updated] = Map.values(WorkshopCalendarHTTP.events(server))
    assert updated["id"] == event["id"]
    assert updated["summary"] == "[Planned] Updated"
    assert updated["location"] == "New hall"

    Agent.update(server, fn state ->
      drifted =
        Map.merge(updated, %{
          "summary" => "Google edit",
          "attendees" => [%{"email" => "private@example.com"}]
        })

      %{state | events: %{event["id"] => drifted}}
    end)

    assert :ok = sync(workshop.id)
    [repaired] = Map.values(WorkshopCalendarHTTP.events(server))
    assert repaired["summary"] == "[Planned] Updated"
    assert repaired["attendees"] == []
    assert Enum.all?(WorkshopCalendarHTTP.mutations(server), &(&1.query == "sendUpdates=none"))
  end

  test "cancellation keeps committee history at its scheduled time even when work arrives after end" do
    server = google_surface!()
    workshop = create_workshop!()
    {:ok, _} = Workshops.publish_workshop(workshop.id)
    assert :ok = sync(workshop.id)
    [event] = Map.values(WorkshopCalendarHTTP.events(server))
    {:ok, _} = Workshops.cancel_workshop(workshop.id)

    assert :ok = sync_at(workshop.id, ~U[2027-03-29 12:00:00Z])
    [cancelled] = Map.values(WorkshopCalendarHTTP.events(server))
    assert cancelled["summary"] == "[Cancelled] Longsword"
    assert cancelled["status"] == "confirmed"
    assert cancelled["start"] == event["start"]
    assert cancelled["end"] == event["end"]
    assert cancelled["location"] == event["location"]
  end

  test "deletion work survives the source, inactive configuration, and event end; repairs do not resurrect it" do
    server = google_surface!()
    workshop = create_workshop!()
    assert :ok = sync(workshop.id)
    config = deactivate!()
    assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id)
    assert Workshops.calendar_projection(workshop.id) == nil
    assert :ok = sync(workshop.id)
    assert [_] = WorkshopCalendarHTTP.mutations(server)
    activate!(config)
    assert :ok = sync_at(workshop.id, ~U[2027-04-01 00:00:00Z])
    assert [%{"status" => "cancelled"}] = Map.values(WorkshopCalendarHTTP.events(server))
    assert :ok = sync(workshop.id)
    assert [_, _] = WorkshopCalendarHTTP.mutations(server)
  end

  test "archival alone leaves an existing committee event unchanged" do
    server = google_surface!()
    workshop = create_workshop!()
    assert :ok = sync(workshop.id)
    %{principal_id: participant} = WorkshopFixtures.member_fixture()
    WorkshopFixtures.registration_fixture(workshop_id: workshop.id, member_user_id: participant)
    assert {:ok, :archived, _} = Workshops.delete_workshop(workshop.id)
    assert :ok = sync(workshop.id)
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "an uncertain successful insert is read back, never duplicated or resent" do
    server = google_surface!()
    Agent.update(server, &%{&1 | uncertain_insert: true})
    workshop = create_workshop!()
    assert {:snooze, 30} = sync(workshop.id)
    assert :ok = sync_at(workshop.id, DateTime.add(@now, 30))
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "a late ambiguous insert cannot escape deletion just because cleanup first observed absence" do
    server = google_surface!()
    Agent.update(server, &%{&1 | defer_insert: true})
    workshop = create_workshop!()
    assert {:snooze, 30} = sync(workshop.id)
    assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id)
    assert :ok = sync_at(workshop.id, DateTime.add(@now, 30))
    assert WorkshopCalendarHTTP.events(server) == %{}

    Agent.update(server, fn state ->
      %{state | events: %{state.delayed["id"] => state.delayed}}
    end)

    assert :ok = WorkshopCalendar.repair(clock: fn -> DateTime.add(@now, 300) end)
    assert :ok = sync_at(workshop.id, DateTime.add(@now, 300))
    assert [%{"status" => "cancelled"}] = Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "a Workshop created and deleted while inactive has no external cleanup to poll" do
    server = google_surface!()
    config = WorkshopCalendar.config()
    Application.put_env(:dhc, WorkshopCalendar, Keyword.put(config, :active, false))
    workshop = create_workshop!()
    assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id)
    Application.put_env(:dhc, WorkshopCalendar, config)
    assert :ok = sync(workshop.id)
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
  end

  test "a deleted organizer event uses a new persisted identity before end" do
    server = google_surface!()
    workshop = create_workshop!()
    assert :ok = sync(workshop.id)
    [first] = Map.values(WorkshopCalendarHTTP.events(server))

    Agent.update(server, fn state ->
      %{state | events: %{first["id"] => %{"id" => first["id"], "status" => "cancelled"}}}
    end)

    assert :ok = sync(workshop.id)

    live =
      Enum.reject(Map.values(WorkshopCalendarHTTP.events(server)), &(&1["status"] == "cancelled"))

    assert [replacement] = live
    refute replacement["id"] == first["id"]
    assert :ok = sync(workshop.id)
    assert [_, _] = WorkshopCalendarHTTP.mutations(server)
  end

  test "conflicting tombstoned identities consume the bounded retry budget rather than looping" do
    Sentry.Test.setup_sentry()
    server = google_surface!()
    workshop = create_workshop!()
    Agent.update(server, &%{&1 | insert_conflict: true})

    now =
      Enum.reduce([30, 60, 120, 240, 480], @now, fn delay, now ->
        assert {:snooze, ^delay} = sync_at(workshop.id, now)
        DateTime.add(now, delay)
      end)

    assert :ok = sync_at(workshop.id, now)
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert count == 6
    assert :ok = sync_at(workshop.id, DateTime.add(now, 86_400))
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
  end

  test "the exact end instant blocks first publication and missing-event recreation" do
    server = google_surface!()
    workshop = create_workshop!()
    assert :ok = sync_at(workshop.id, ~U[2027-03-28 11:00:00Z])
    assert WorkshopCalendarHTTP.mutations(server) == []
    assert :ok = sync_at(workshop.id, ~U[2027-03-28 10:59:59Z])
    Agent.update(server, &%{&1 | events: %{}})
    assert :ok = sync_at(workshop.id, ~U[2027-03-28 11:00:00Z])
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "inactive configuration during token refresh prevents starting an event mutation" do
    parent = self()
    config = WorkshopCalendar.config()

    server =
      google_surface!(fn conn ->
        if conn.host == "oauth2.googleapis.com" do
          send(parent, :refresh_seen)
          Application.put_env(:dhc, WorkshopCalendar, Keyword.put(config, :active, false))
        end
      end)

    workshop = create_workshop!()
    assert :ok = sync(workshop.id)
    assert_receive :refresh_seen
    assert WorkshopCalendarHTTP.mutations(server) == []
    activate!(config)
    WorkshopCalendarHTTP.stub(server)
    assert :ok = sync(workshop.id)
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "inactive deployment and invalid configuration cannot fail a Workshop command or send to Google" do
    server = google_surface!()
    config = WorkshopCalendar.config()
    Application.put_env(:dhc, WorkshopCalendar, Keyword.put(config, :active, false))
    workshop = create_workshop!()
    assert {:ok, _} = Workshops.publish_workshop(workshop.id)
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []

    Application.put_env(
      :dhc,
      WorkshopCalendar,
      Keyword.put(config, :participant_calendar_id, "committee@test.invalid")
    )

    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
    assert Workshops.calendar_projection(workshop.id).status == "published"
  end

  test "permanent failures report once across repeated reconciliation" do
    Sentry.Test.setup_sentry()
    server = google_surface!()
    workshop = create_workshop!()
    Agent.update(server, &%{&1 | status: 401})
    assert :ok = sync(workshop.id)

    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    requests = length(WorkshopCalendarHTTP.requests(server))
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.requests(server)) == requests
    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "terminal authorization failure retains later cancellation without resetting its report episode" do
    Sentry.Test.setup_sentry()
    server = google_surface!()
    workshop = create_workshop!()
    {:ok, _} = Workshops.publish_workshop(workshop.id)
    args = %{"source_kind" => "workshop", "source_id" => workshop.id}
    assert :ok = perform_job(SyncWorker, args)
    Agent.update(server, &%{&1 | revoked: true})
    assert :ok = perform_job(SyncWorker, args)

    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    request_count = length(WorkshopCalendarHTTP.requests(server))
    config = deactivate!()
    assert {:ok, _} = Workshops.cancel_workshop(workshop.id)
    Agent.update(server, &%{&1 | revoked: false})
    activate!(config)
    assert :ok = perform_job(SyncWorker, args)

    assert [%{"summary" => "Longsword"}] =
             Map.values(WorkshopCalendarHTTP.events(server))

    assert Workshops.calendar_projection(workshop.id).status == "cancelled"
    assert length(WorkshopCalendarHTTP.requests(server)) == request_count
    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "transient failures retry with bounded backoff and retain one exhausted failure report" do
    Sentry.Test.setup_sentry()
    server = google_surface!()
    workshop = create_workshop!()
    Agent.update(server, &%{&1 | status: 503})

    now =
      Enum.reduce([30, 60, 120, 240, 480], @now, fn delay, now ->
        assert {:snooze, ^delay} = sync_at(workshop.id, now)
        DateTime.add(now, delay)
      end)

    assert :ok = sync_at(workshop.id, now)

    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    count = length(WorkshopCalendarHTTP.requests(server))
    assert :ok = sync_at(workshop.id, DateTime.add(now, 86_400))
    assert length(WorkshopCalendarHTTP.requests(server)) == count
  end

  test "a repair pass discovers a source whose original wake-up was absent" do
    server = google_surface!()

    workshop =
      WorkshopFixtures.workshop_fixture(
        start_date: ~U[2027-03-28 09:00:00Z],
        end_date: ~U[2027-03-28 11:00:00Z]
      )

    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert_enqueued(worker: SyncWorker, args: %{source_kind: "workshop", source_id: workshop.id})
    assert :ok = sync(workshop.id)
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
  end

  test "the background driver consumes identifier-only intent through the same protocol" do
    server = google_surface!()
    workshop = create_workshop!()
    [job] = all_enqueued(worker: SyncWorker)
    assert job.args == %{"source_kind" => "workshop", "source_id" => workshop.id}

    assert :ok = perform_job(SyncWorker, job.args)

    assert [%{"summary" => "[Planned] Longsword"}] =
             Map.values(WorkshopCalendarHTTP.events(server))

    assert :ok = perform_job(SyncWorker, job.args)
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  defp google_surface!(before_request \\ fn _conn -> :ok end) do
    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server, before_request)
    server
  end

  defp create_workshop! do
    %{principal_id: principal_id} = WorkshopFixtures.member_fixture()

    {:ok, workshop} =
      Workshops.create_workshop(
        %{
          title: "Longsword",
          description: "PRIVATE notes, medical and payment details",
          location: "Club hall",
          start_date: ~U[2027-03-28 09:00:00Z],
          end_date: ~U[2027-03-28 11:00:00Z],
          max_capacity: 20,
          price_member: 1000.0,
          price_non_member: 2000.0
        },
        principal_id
      )

    workshop
  end

  defp sync(id), do: WorkshopCalendar.sync(:workshop, id, clock: fn -> @now end)
  defp sync_at(id, now), do: WorkshopCalendar.sync(:workshop, id, clock: fn -> now end)
end
