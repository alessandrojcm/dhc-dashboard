defmodule Dhc.WorkshopCalendar.ConcurrencyTest do
  use Dhc.DataCase, async: false

  import Dhc.ConcurrencyHelpers

  alias Dhc.Repo
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google}
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  @now ~U[2027-03-01 12:00:00Z]

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

  test "duplicate workers never send concurrent stale snapshots", %{server: server} do
    workshop = committed_workshop!()
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "POST" do
        refute Repo.in_transaction?()
        send(parent, {:creating, self()})
        receive do: (:continue -> :ok)
      end
    end)

    first = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:creating, caller}, 5_000
    second = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert {:snooze, 5} = Task.await(second)
    send(caller, :continue)
    assert :ok = Task.await(first)
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  test "a source edit during insert is not acknowledged as current and converges without another event",
       %{server: server} do
    workshop = committed_workshop!()
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "POST" do
        send(parent, {:creating, self()})
        receive do: (:continue -> :ok)
      end
    end)

    first = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:creating, caller}, 5_000

    outside_sandbox(fn ->
      assert {:ok, _} = Workshops.update_workshop(workshop.id, %{title: "Current title"})
    end)

    send(caller, :continue)
    assert {:snooze, 1} = Task.await(first)
    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    assert [%{"summary" => "[Planned] Current title"}] =
             Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "hard deletion while insert is in flight leaves durable removal work", %{server: server} do
    workshop = committed_workshop!()
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "POST" do
        send(parent, {:creating, self()})
        receive do: (:continue -> :ok)
      end
    end)

    first = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:creating, caller}, 5_000
    outside_sandbox(fn -> assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id) end)
    send(caller, :continue)
    assert {:snooze, 1} = Task.await(first)
    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)
    assert [%{"status" => "cancelled"}] = Map.values(WorkshopCalendarHTTP.events(server))
  end

  test "a crash after Google accepted insert recovers the same event after ownership expires", %{
    server: server
  } do
    workshop = committed_workshop!()
    parent = self()

    WorkshopCalendarHTTP.stub(server)

    # Pause after the HTTP adapter returns but before the local acknowledgment.
    handler = "calendar-crash-#{workshop.id}"
    owner = self()

    :telemetry.attach(
      handler,
      [:dhc, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata.query =~ "FOR UPDATE" and metadata.query =~ "workshop_calendar_events" and
             match?([_], WorkshopCalendarHTTP.mutations(server)) and self() != owner do
          send(parent, {:before_ack, self()})
          receive do: (:continue -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    task = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:before_ack, _caller}, 5_000
    Task.shutdown(task, :brutal_kill)
    :telemetry.detach(handler)
    WorkshopCalendarHTTP.stub(server)

    outside_sandbox(fn ->
      assert :ok =
               WorkshopCalendar.sync(:workshop, workshop.id,
                 clock: fn -> DateTime.add(@now, 121) end
               )
    end)

    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
    assert [_] = WorkshopCalendarHTTP.mutations(server)
  end

  defp committed_workshop! do
    {workshop, member} =
      outside_sandbox(fn ->
        member = WorkshopFixtures.member_fixture()

        {:ok, workshop} =
          Workshops.create_workshop(
            %{
              title: "Longsword",
              location: "Club hall",
              start_date: ~U[2027-03-28 09:00:00Z],
              end_date: ~U[2027-03-28 11:00:00Z],
              max_capacity: 20,
              price_member: 1000.0,
              price_non_member: 2000.0
            },
            member.principal_id
          )

        {workshop, member}
      end)

    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^workshop.id)
        )

        Repo.delete_all(from(e in Event, where: e.source_id == ^workshop.id))
        Repo.delete_all(from(w in Workshops.Workshop, where: w.id == ^workshop.id))

        Repo.delete_all(
          from(m in Dhc.MemberProfiles.MemberProfile, where: m.id == ^member.principal_id)
        )

        Repo.delete_all(
          from(p in Dhc.UserProfiles.UserProfile, where: p.principal_id == ^member.principal_id)
        )

        Repo.delete_all(from(p in Dhc.Auth.Principal, where: p.id == ^member.principal_id))
      end)
    end)

    workshop
  end

  defp sync(id), do: WorkshopCalendar.sync(:workshop, id, clock: fn -> @now end)
end
