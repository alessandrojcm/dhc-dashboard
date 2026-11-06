defmodule Dhc.WorkshopCalendar.BeginnersConcurrencyTest do
  use Dhc.DataCase, async: false

  import Ecto.Query
  import Dhc.ConcurrencyHelpers

  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google}
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
    %{server: server}
  end

  test "a reschedule racing an in-flight insert converges one event on the current schedule", %{
    server: server
  } do
    {workshop, staff} = committed_workshop!()
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "POST" do
        send(parent, {:google_insert_started, self()})

        receive do
          :continue_google_insert -> :ok
        end
      end
    end)

    sync_task = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:google_insert_started, google}, 5_000

    outside_sandbox(fn ->
      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, staff},
                 {:reschedule_workshop, workshop.id, rescheduled_attrs()},
                 clock: Fixtures.clock(@now)
               )
    end)

    send(google, :continue_google_insert)
    assert {:snooze, 1} = Task.await(sync_task, 5_000)

    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert event["summary"] == "Beginners' Workshop"
    assert_event_times(event, ~D[2027-04-04], ~T[12:00:00], ~T[14:00:00])
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
  end

  test "a cancellation racing an in-flight update converges the existing event on the cancelled schedule",
       %{server: server} do
    {workshop, staff} = committed_workshop!()
    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)
    [created] = Map.values(WorkshopCalendarHTTP.events(server))

    outside_sandbox(fn ->
      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, staff},
                 {:reschedule_workshop, workshop.id, rescheduled_attrs()},
                 clock: Fixtures.clock(@now)
               )
    end)

    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "PUT" do
        send(parent, {:google_update_started, self()})

        receive do
          :continue_google_update -> :ok
        end
      end
    end)

    sync_task = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:google_update_started, google}, 5_000

    outside_sandbox(fn ->
      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, staff},
                 {:cancel_workshop, workshop.id, %{}},
                 clock: Fixtures.clock(@now)
               )
    end)

    send(google, :continue_google_update)
    assert {:snooze, 1} = Task.await(sync_task, 5_000)

    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert event["id"] == created["id"]
    assert event["summary"] == "[Cancelled] Beginners' Workshop"
    assert_event_times(event, ~D[2027-04-04], ~T[12:00:00], ~T[14:00:00])
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
  end

  defp committed_workshop! do
    {workshop, staff} =
      outside_sandbox(fn ->
        staff = Fixtures.staff_fixture()

        workshop =
          Fixtures.scheduled_fixture(staff, %{
            "date" => "2027-03-28",
            "start_time" => "10:00",
            "end_time" => "12:00",
            "venue" => "Club hall"
          })

        {workshop, staff}
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^workshop.id)
        )

        Repo.delete_all(
          from(e in Event,
            where: e.source_kind == "beginners_workshop" and e.source_id == ^workshop.id
          )
        )

        Repo.delete_all(
          from(w in BeginnersWorkshops.BeginnersWorkshop, where: w.id == ^workshop.id)
        )

        Repo.delete_all(from(r in Dhc.Auth.UserRole, where: r.principal_id == ^staff))
        Repo.delete_all(from(m in Dhc.MemberProfiles.MemberProfile, where: m.id == ^staff))
        Repo.delete_all(from(p in Dhc.UserProfiles.UserProfile, where: p.principal_id == ^staff))
        Repo.delete_all(from(p in Dhc.Auth.Principal, where: p.id == ^staff))
      end)
    end)

    {workshop, staff}
  end

  defp rescheduled_attrs do
    %{
      "date" => "2027-04-04",
      "start_time" => "12:00",
      "end_time" => "14:00",
      "venue" => "Current hall"
    }
  end

  defp assert_event_times(event, date, start_time, end_time) do
    assert event["start"]["dateTime"] ==
             date |> ClubCalendar.to_utc(start_time) |> DateTime.to_iso8601()

    assert event["end"]["dateTime"] ==
             date |> ClubCalendar.to_utc(end_time) |> DateTime.to_iso8601()
  end

  defp sync(id), do: WorkshopCalendar.sync(:beginners_workshop, id, clock: fn -> @now end)
end
