defmodule Dhc.WorkshopCalendar.BeginnersSyncTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP

  @now ~U[2026-10-09 11:00:00Z]

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "isolated-client",
      client_secret: "isolated-secret",
      refresh_token: "isolated-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server)
    %{server: server, staff: Fixtures.staff_fixture()}
  end

  test "scheduling immediately queues an identifier-only, roster-free committee event", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)
    [job] = all_enqueued(worker: SyncWorker)
    assert job.args == %{"source_kind" => "beginners_workshop", "source_id" => workshop.id}
    assert WorkshopCalendarHTTP.requests(server) == []
    assert :ok = perform_job(SyncWorker, job.args)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert event["summary"] == "Beginners' Workshop"
    assert event["start"]["dateTime"] == "2027-03-28T09:00:00Z"
    assert event["end"]["dateTime"] == "2027-03-28T11:00:00Z"
    assert event["location"] == "Club hall"
    assert event["description"] =~ "/dashboard/beginners-workshop/workshops/#{workshop.id}"
    refute Map.has_key?(event, "attendees")
    assert Enum.all?(WorkshopCalendarHTTP.mutations(server), &(&1.query == "sendUpdates=none"))
  end

  test "rescheduling across Dublin DST updates one event; unchanged and internal changes are no-ops",
       %{
         server: server,
         staff: staff
       } do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id)
    [first] = Map.values(WorkshopCalendarHTTP.events(server))
    assert :ok = sync(workshop.id)
    assert {:ok, _} = command(staff, {:update_workshop, workshop.id, %{capacity: 18}})
    assert :ok = sync(workshop.id)
    assert [_] = WorkshopCalendarHTTP.mutations(server)

    assert {:ok, _} =
             command(
               staff,
               {:reschedule_workshop, workshop.id,
                %{date: "2027-10-31", start_time: "10:00", end_time: "13:00", venue: "New hall"}}
             )

    assert :ok = sync(workshop.id)
    [moved] = Map.values(WorkshopCalendarHTTP.events(server))
    assert moved["id"] == first["id"]
    assert moved["start"]["dateTime"] == "2027-10-31T10:00:00Z"
    assert moved["end"]["dateTime"] == "2027-10-31T13:00:00Z"
    assert moved["location"] == "New hall"
  end

  test "committee drift repair removes participant data without copying any person or credential",
       %{
         server: server,
         staff: staff
       } do
    workshop = schedule!(staff)
    person = Fixtures.waiting_person_fixture(@now, first_name: "PRIVATE PERSON")
    assert {:ok, _} = command(staff, {:fast_track, workshop.id, {:waitlist_entry, person.id}})
    assert :ok = sync(workshop.id)
    [event] = Map.values(WorkshopCalendarHTTP.events(server))

    Agent.update(server, fn state ->
      drifted =
        Map.merge(event, %{
          "summary" => "Google edit",
          "attendees" => [%{"email" => person.email}]
        })

      %{state | events: %{event["id"] => drifted}}
    end)

    assert :ok = sync(workshop.id)
    [repaired] = Map.values(WorkshopCalendarHTTP.events(server))
    assert repaired["summary"] == "Beginners' Workshop"
    assert repaired["attendees"] == []
    payloads = WorkshopCalendarHTTP.mutations(server) |> Enum.map(& &1.payload) |> Jason.encode!()
    refute payloads =~ person.email
    refute payloads =~ "PRIVATE"
    refute payloads =~ "/beginners/intake/"
    refute payloads =~ "fee_cents"
    refute payloads =~ "link_token"

    assert Map.keys(event) |> Enum.sort() ==
             ~w(description end etag guestsCanInviteOthers guestsCanModify guestsCanSeeOtherGuests id location start status summary visibility)
  end

  test "cancellation keeps the last scheduled time and remains owed after end", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id)
    [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert {:ok, _} = command(staff, {:cancel_workshop, workshop.id, %{reason: "PRIVATE"}})
    assert :ok = sync(workshop.id, ~U[2027-03-29 12:00:00Z])
    [cancelled] = Map.values(WorkshopCalendarHTTP.events(server))
    assert cancelled["id"] == event["id"]
    assert cancelled["summary"] == "[Cancelled] Beginners' Workshop"
    assert cancelled["status"] == "confirmed"
    assert cancelled["start"] == event["start"]
    assert cancelled["end"] == event["end"]
    refute Jason.encode!(cancelled) =~ "PRIVATE"
  end

  test "a missing legacy end is reported without Google and an authorized backfill recovers it",
       %{server: server, staff: staff} do
    workshop = schedule!(staff)
    # Legacy storage allows unknown ends; ordinary commands never create them.
    legacy = Repo.get!(Dhc.BeginnersWorkshops.BeginnersWorkshop, workshop.id)
    legacy |> Ecto.Changeset.change(end_time: nil) |> Repo.update!()
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
    assert {:ok, %{notifications: [notification]}} = Dhc.Notifications.list_for_user(staff)
    assert notification.body =~ "end time"
    assert :ok = sync(workshop.id)
    assert {:ok, %{notifications: [_]}} = Dhc.Notifications.list_for_user(staff)

    assert {:ok, _} = command(staff, {:backfill_end_time, workshop.id, %{end_time: "12:00"}})
    assert :ok = sync(workshop.id)

    assert [%{"end" => %{"dateTime" => "2027-03-28T11:00:00Z"}}] =
             Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "unknown legacy ends discovered by repair do not guess a duration", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)
    legacy = Repo.get!(Dhc.BeginnersWorkshops.BeginnersWorkshop, workshop.id)
    legacy |> Ecto.Changeset.change(end_time: nil) |> Repo.update!()
    # Simulate an existing source without any previous integration intent.
    Repo.delete_all(Dhc.WorkshopCalendar.Event)
    Repo.delete_all(Oban.Job)
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)

    assert_enqueued(
      worker: SyncWorker,
      args: %{source_kind: "beginners_workshop", source_id: workshop.id}
    )

    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
  end

  test "Google outage cannot undo a schedule and retries converge without duplicate events", %{
    server: server,
    staff: staff
  } do
    Agent.update(server, &%{&1 | status: 503})
    workshop = schedule!(staff)
    assert {:snooze, 30} = sync(workshop.id)
    assert BeginnersWorkshops.calendar_projection(workshop.id).status == "scheduled"
    Agent.update(server, &%{&1 | status: nil, uncertain_insert: true})
    assert {:snooze, 60} = sync(workshop.id, DateTime.add(@now, 30))
    assert :ok = sync(workshop.id, DateTime.add(@now, 90))
    assert [_] = Map.values(WorkshopCalendarHTTP.events(server))
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "persistent failures alert only the Beginners' Workshop recipients once per durable episode",
       %{server: server, staff: staff} do
    outsider = Fixtures.staff_fixture("workshop_coordinator")
    workshop = schedule!(staff)
    Agent.update(server, &%{&1 | status: 401})
    assert :ok = sync(workshop.id)
    assert {:ok, %{notifications: [notification]}} = Dhc.Notifications.list_for_user(staff)
    assert notification.body =~ "Workshop places are unchanged"
    assert notification.body =~ "authorization"
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(outsider)
    count = length(WorkshopCalendarHTTP.requests(server))
    Repo.delete_all(Dhc.Notifications.Notification)
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.requests(server)) == count
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(staff)
  end

  test "pause and inactive deployment send nothing; resume reconciles cancellation not stale scheduling",
       %{server: server, staff: staff} do
    config = WorkshopCalendar.config()
    Application.put_env(:dhc, WorkshopCalendar, Keyword.put(config, :active, false))
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
    Application.put_env(:dhc, WorkshopCalendar, config)
    assert :ok = sync(workshop.id)
    assert :ok = WorkshopCalendar.pause()
    assert {:ok, _} = command(staff, {:cancel_workshop, workshop.id, %{}})
    count = length(WorkshopCalendarHTTP.requests(server))
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.requests(server)) == count
    assert :ok = WorkshopCalendar.resume()
    assert :ok = sync(workshop.id)

    assert [%{"summary" => "[Cancelled] Beginners' Workshop"}] =
             Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "early attendance finalisation preserves the event and its original scheduled end", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id)
    assert {:ok, _} = command(staff, {:finish_workshop, workshop.id}, ~U[2027-03-28 09:30:00Z])
    assert :ok = sync(workshop.id, ~U[2027-03-28 09:30:00Z])
    assert [_] = WorkshopCalendarHTTP.mutations(server)

    assert [
             %{
               "summary" => "Beginners' Workshop",
               "end" => %{"dateTime" => "2027-03-28T11:00:00Z"}
             }
           ] = Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "missing organizer events are recreated only strictly before the scheduled end", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id)
    [first] = Map.values(WorkshopCalendarHTTP.events(server))
    Agent.update(server, &%{&1 | events: %{first["id"] => %{"status" => "cancelled"}}})
    assert :ok = sync(workshop.id, ~U[2027-03-28 10:59:59Z])

    [replacement] =
      Enum.reject(Map.values(WorkshopCalendarHTTP.events(server)), &(&1["status"] == "cancelled"))

    refute replacement["id"] == first["id"]
    Agent.update(server, &%{&1 | events: %{}})
    assert :ok = sync(workshop.id, ~U[2027-03-28 11:00:00Z])
    assert [_, _] = WorkshopCalendarHTTP.mutations(server)
    assert WorkshopCalendarHTTP.events(server) == %{}
  end

  test "delayed first publication never creates a past event", %{server: server, staff: staff} do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id, ~U[2027-03-28 11:00:00Z])
    assert WorkshopCalendarHTTP.mutations(server) == []
  end

  test "a failed stale observation cannot park a rescheduled source", %{
    server: server,
    staff: staff
  } do
    workshop = schedule!(staff)

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "GET" do
        assert {:ok, _} =
                 command(
                   staff,
                   {:reschedule_workshop, workshop.id,
                    %{start_time: "10:00", end_time: "13:00", venue: "Current hall"}}
                 )

        Agent.update(server, &%{&1 | status: 401})
      end
    end)

    assert {:snooze, 1} = sync(workshop.id)
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(staff)
    Agent.update(server, &%{&1 | status: nil})
    WorkshopCalendarHTTP.stub(server)
    assert :ok = sync(workshop.id)

    assert [%{"location" => "Current hall", "end" => %{"dateTime" => "2027-03-28T12:00:00Z"}}] =
             Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "a rejected multi-workshop schedule rolls back its Calendar intents too", %{
    server: server,
    staff: staff
  } do
    assert {:error, {:workshop, 1, _}} =
             command(staff, {:schedule_workshop, [Fixtures.workshop_attrs(), %{}]})

    assert all_enqueued(worker: SyncWorker) == []
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert all_enqueued(worker: SyncWorker) == []
    assert WorkshopCalendarHTTP.requests(server) == []
  end

  test "source kinds isolate identical immutable IDs", %{server: server, staff: staff} do
    workshop = schedule!(staff)

    regular =
      Dhc.WorkshopFixtures.workshop_fixture(
        start_date: ~U[2027-03-28 09:00:00Z],
        end_date: ~U[2027-03-28 11:00:00Z]
      )

    regular |> Ecto.Changeset.change(id: workshop.id) |> Repo.update!()
    assert :ok = sync(workshop.id)
    assert :ok = WorkshopCalendar.sync(:workshop, workshop.id, clock: fn -> @now end)
    assert [first, second] = events = Map.values(WorkshopCalendarHTTP.events(server))
    refute first["id"] == second["id"]
    assert Enum.any?(events, &(&1["summary"] == "Beginners' Workshop"))
    assert Enum.any?(events, &(&1["summary"] == "[Planned] Test Workshop"))
  end

  defp command(staff, operation, now \\ @now),
    do: BeginnersWorkshops.execute({:staff, staff}, operation, clock: Fixtures.clock(now))

  defp schedule!(staff) do
    Fixtures.scheduled_fixture(staff, %{
      "date" => "2027-03-28",
      "start_time" => "10:00",
      "end_time" => "12:00",
      "venue" => "Club hall"
    })
  end

  defp sync(id, now \\ @now),
    do: WorkshopCalendar.sync(:beginners_workshop, id, clock: fn -> now end)
end
