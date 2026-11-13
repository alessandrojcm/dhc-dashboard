defmodule Dhc.WorkshopCalendar.DestinationBackfillSyncTest do
  @moduledoc """
  ALE-443: a reviewed destination backfill drives the existing Calendar
  protocol against the Req.Test Google fixture — the same event identities,
  retained recipients and surviving RSVPs, normal participant updates, and no
  extra no-op updates, including under in-flight work and duplicate drivers.
  """
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query
  import Dhc.ConcurrencyHelpers
  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.DestinationBackfill
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google, Recipients}
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops.{ExternalUser, Registration, Workshop}

  @now ~U[2027-03-01 12:00:00Z]
  @start ~U[2027-03-28 09:00:00Z]
  @finish ~U[2027-03-28 11:00:00Z]
  @location "National Basketball Arena, Tymon Park, Dublin 6w"

  @mapping %{
    "mappings" => [
      %{
        "venue" => "Club hall",
        "destination" => %{
          "destination_text" => "National Basketball Arena, Tymon Park, Dublin 6w"
        }
      }
    ]
  }

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "backfill-sync-client",
      client_secret: "backfill-sync-secret",
      refresh_token: "backfill-sync-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)

    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server)
    %{server: server}
  end

  test "enrichment updates the existing events, keeps recipients and RSVPs, then stays silent",
       %{server: server} do
    staff = staff!()
    workshop = workshop!()
    registration = confirmed!(workshop, "participant@example.com")

    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    original = participant(server)
    committee = committee(server)
    rsvp!(server, original, "accepted")
    recipients = Recipients.list(event_row(workshop.id, "participant"))
    before = WorkshopCalendarHTTP.mutations(server)

    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)
    # Enrichment queues no workshop email of its own: only Calendar intent.
    assert Enum.all?(all_enqueued(), &(&1.worker == "Dhc.WorkshopCalendar.Workers.SyncWorker"))

    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)

    updated = participant(server)
    assert updated["id"] == original["id"]
    assert updated["location"] == @location

    assert updated["attendees"] == [
             %{"email" => registration.email, "responseStatus" => "accepted"}
           ]

    assert committee(server)["id"] == committee["id"]
    assert committee(server)["location"] == @location
    assert map_size(WorkshopCalendarHTTP.events(server)) == 2
    refute Jason.encode!(WorkshopCalendarHTTP.events(server)) =~ "maps.app.goo.gl"

    # A normal meaningful participant update (Google may email), committee
    # updates stay silent.
    new = WorkshopCalendarHTTP.mutations(server) -- before
    assert Enum.any?(new, &(&1.query == "sendUpdates=all"))

    assert Enum.all?(new, fn m ->
             String.contains?(m.path, "participants") == (m.query == "sendUpdates=all")
           end)

    assert Recipients.list(event_row(workshop.id, "participant")) == recipients

    # Converged: neither audience updates again, and repeating the plan is a
    # no-op that records no further intent.
    settled = WorkshopCalendarHTTP.mutations(server)
    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    assert WorkshopCalendarHTTP.mutations(server) == settled

    revision = event_row(workshop.id, "committee").revision
    assert %{results: [%{outcome: :unchanged}]} = apply_current!(staff, workshop)
    assert event_row(workshop.id, "committee").revision == revision
  end

  test "inactive sending retains the change and intent without Google, then converges on activation",
       %{server: server} do
    staff = staff!()
    workshop = workshop!()
    confirmed!(workshop, "inactive@example.com")
    config = deactivate!()

    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)
    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    assert WorkshopCalendarHTTP.requests(server) == []
    assert %Event{revision: revision} = event_row(workshop.id, "committee")
    assert revision > 1

    activate!(config)
    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    assert participant(server)["location"] == @location
    assert committee(server)["location"] == @location
    assert map_size(WorkshopCalendarHTTP.events(server)) == 2
  end

  test "an RSVP edited while the destination update is in flight survives the conditional retry",
       %{server: server} do
    staff = staff!()
    workshop = workshop!()
    registration = confirmed!(workshop, "rsvp@example.com")
    assert :ok = sync(workshop.id, :participant)
    original = participant(server)
    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)

    edited? = start_supervised!({Agent, fn -> false end}, id: :rsvp_edited)

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.method == "PUT" and not Agent.get(edited?, & &1) do
        Agent.update(edited?, fn _ -> true end)
        rsvp!(server, original, "tentative")
      end
    end)

    assert {:snooze, 30} = sync(workshop.id, :participant)
    assert :ok = sync(workshop.id, :participant, DateTime.add(@now, 30))

    updated = participant(server)
    assert updated["id"] == original["id"]
    assert updated["location"] == @location

    assert updated["attendees"] == [
             %{"email" => registration.email, "responseStatus" => "tentative"}
           ]

    settled = WorkshopCalendarHTTP.mutations(server)
    assert :ok = sync(workshop.id, :participant, DateTime.add(@now, 60))
    assert WorkshopCalendarHTTP.mutations(server) == settled
  end

  test "an ambiguous update success is read back instead of repeated", %{server: server} do
    staff = staff!()
    workshop = workshop!()
    confirmed!(workshop, "ambiguous@example.com")
    assert :ok = sync(workshop.id, :participant)
    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)

    Agent.update(server, &%{&1 | uncertain_update: true})
    assert {:snooze, 30} = sync(workshop.id, :participant)
    count = length(WorkshopCalendarHTTP.mutations(server))

    assert :ok = sync(workshop.id, :participant, DateTime.add(@now, 30))
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    assert participant(server)["location"] == @location
    assert map_size(WorkshopCalendarHTTP.events(server)) == 1
  end

  test "an enrichment that reaches Google only after the event ended changes no detail",
       %{server: server} do
    staff = staff!()
    workshop = workshop!()
    confirmed!(workshop, "late@example.com")
    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)
    before = WorkshopCalendarHTTP.mutations(server)

    assert :ok = sync(workshop.id, :committee, @finish)
    assert :ok = sync(workshop.id, :participant, @finish)

    assert WorkshopCalendarHTTP.mutations(server) == before
    assert participant(server)["location"] == "Club hall"

    # And a backfill at or after the start is refused outright.
    later = workshop!()

    assert %{results: [%{outcome: :refused, reason: :started}]} =
             apply!(staff, later, @start)
  end

  describe "concurrent drivers" do
    test "a destination change during in-flight Google work fences the stale run and converges",
         %{server: server} do
      ctx = committed!()
      outside_sandbox(fn -> confirmed!(ctx.workshop, "first@example.com") end)
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id, :participant) end)

      # A newly confirmed place's attendee addition is in flight when the
      # enrichment commits.
      outside_sandbox(fn -> confirmed!(ctx.workshop, "second@example.com") end)
      parent = self()

      WorkshopCalendarHTTP.stub(server, fn conn ->
        if conn.method == "PUT" do
          send(parent, {:put_started, self()})
          receive do: (:continue -> :ok)
        end
      end)

      stale = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id, :participant) end) end)
      assert_receive {:put_started, google}, 5_000

      outside_sandbox(fn ->
        assert %{results: [%{outcome: :changed}]} = apply!(ctx.staff, ctx.workshop)
      end)

      send(google, :continue)
      assert {:snooze, 1} = Task.await(stale, 5_000)

      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id, :participant) end)

      assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
      assert event["location"] == @location

      assert event["attendees"] == [
               %{"email" => "first@example.com"},
               %{"email" => "second@example.com"}
             ]

      settled = WorkshopCalendarHTTP.mutations(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id, :participant) end)
      assert WorkshopCalendarHTTP.mutations(server) == settled
    end

    test "duplicate drivers after enrichment send one update and no duplicate event",
         %{server: server} do
      ctx = committed!()
      outside_sandbox(fn -> confirmed!(ctx.workshop, "duplicate@example.com") end)
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id, :participant) end)

      outside_sandbox(fn ->
        assert %{results: [%{outcome: :changed}]} = apply!(ctx.staff, ctx.workshop)
      end)

      before = length(WorkshopCalendarHTTP.mutations(server))
      parent = self()

      WorkshopCalendarHTTP.stub(server, fn conn ->
        if conn.method == "PUT" do
          send(parent, {:update_started, self()})
          receive do: (:continue -> :ok)
        end
      end)

      first = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id, :participant) end) end)
      assert_receive {:update_started, google}, 5_000

      second =
        Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id, :participant) end) end)

      assert {:snooze, 5} = Task.await(second, 5_000)
      send(google, :continue)
      assert :ok = Task.await(first, 5_000)

      assert length(WorkshopCalendarHTTP.mutations(server)) == before + 1
      assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
      assert event["location"] == @location
      assert event["attendees"] == [%{"email" => "duplicate@example.com"}]
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp apply!(staff, workshop, now \\ @now) do
    {:ok, mapping} = DestinationBackfill.parse_mapping(@mapping)

    preview =
      mapping
      |> DestinationBackfill.preview(clock: fn -> @now end)
      |> Jason.encode!()
      |> Jason.decode!()

    targets = Enum.filter(preview["proposed_targets"], &(&1["source_id"] == workshop.id))

    {:ok, result} =
      DestinationBackfill.apply_plan(
        %{"mapping" => preview["mapping"], "approved_targets" => targets},
        {:staff, staff},
        clock: fn -> now end
      )

    result
  end

  # Re-approve the Workshop as it now is (its enriched destination included).
  defp apply_current!(staff, workshop) do
    facts = Dhc.Workshops.DestinationEnrichment.facts(Repo.get!(Workshop, workshop.id))

    target =
      %{
        source_kind: "workshop",
        source_id: workshop.id,
        expected: Map.take(facts, [:label, :status, :date, :start_time, :end_time, :destination])
      }
      |> Jason.encode!()
      |> Jason.decode!()

    {:ok, result} =
      DestinationBackfill.apply_plan(
        %{"mapping" => @mapping, "approved_targets" => [target]},
        {:staff, staff},
        clock: fn -> @now end
      )

    result
  end

  defp workshop! do
    WorkshopFixtures.workshop_fixture(
      status: "published",
      location: "Club hall",
      start_date: @start,
      end_date: @finish
    )
  end

  defp confirmed!(workshop, email) do
    attendee = WorkshopFixtures.external_user_fixture(%{email: email})

    registration =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        status: "confirmed",
        external_user_id: attendee.id,
        email: attendee.email
      )

    {:ok, :ok} =
      Repo.transaction(fn ->
        WorkshopCalendar.confirm_place(
          :workshop,
          workshop.id,
          registration.id,
          registration.email
        )
      end)

    registration
  end

  defp staff! do
    member = WorkshopFixtures.member_fixture()

    for role <- ["member", "workshop_coordinator"],
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end

  defp rsvp!(server, event, status) do
    Agent.update(server, fn state ->
      current = Map.fetch!(state.events, event["id"])

      attendees =
        Enum.map(current["attendees"], &Map.put(&1, "responseStatus", status))

      sequence = state.sequence + 1

      replaced =
        current |> Map.put("attendees", attendees) |> Map.put("etag", "\"#{sequence}\"")

      %{state | events: Map.put(state.events, event["id"], replaced), sequence: sequence}
    end)
  end

  defp sync(id, audience, now \\ @now),
    do: WorkshopCalendar.sync(:workshop, id, audience: audience, clock: fn -> now end)

  defp event_row(workshop_id, audience),
    do: Repo.get_by(Event, source_kind: "workshop", source_id: workshop_id, audience: audience)

  defp participant(server),
    do:
      server
      |> WorkshopCalendarHTTP.events()
      |> Map.values()
      |> Enum.find(&Map.has_key?(&1, "attendees"))

  defp committee(server),
    do:
      server
      |> WorkshopCalendarHTTP.events()
      |> Map.values()
      |> Enum.reject(&Map.has_key?(&1, "attendees"))
      |> hd()

  defp committed! do
    ctx = outside_sandbox(fn -> %{staff: staff!(), workshop: workshop!()} end)
    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    ctx
  end

  defp cleanup!(%{staff: staff, workshop: workshop}) do
    id = workshop.id
    Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^id))
    Repo.delete_all(from(e in Event, where: e.source_kind == "workshop" and e.source_id == ^id))

    external_ids =
      Repo.all(
        from(r in Registration,
          where: r.club_activity_id == ^id and not is_nil(r.external_user_id),
          select: r.external_user_id
        )
      )

    Repo.delete_all(from(r in Registration, where: r.club_activity_id == ^id))
    Repo.delete_all(from(u in ExternalUser, where: u.id in ^external_ids))
    Repo.delete_all(from(w in Workshop, where: w.id == ^id))
    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^staff))
    Repo.delete_all(from(mp in MemberProfile, where: mp.id == ^staff))
    Repo.delete_all(from(up in UserProfile, where: up.principal_id == ^staff))
    Repo.delete_all(from(p in Principal, where: p.id == ^staff))
  end
end
