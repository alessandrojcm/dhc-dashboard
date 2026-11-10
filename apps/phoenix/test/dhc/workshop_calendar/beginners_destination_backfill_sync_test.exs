defmodule Dhc.WorkshopCalendar.BeginnersDestinationBackfillSyncTest do
  @moduledoc """
  ALE-444: a reviewed destination backfill applied to a Beginners' Workshop
  drives the existing Calendar protocol against the Req.Test Google fixture —
  both audiences' native locations, the same event identities, retained
  recipients and surviving RSVPs, a normal participant update, silent
  repeats, no detail change after the event ended, and outstanding place
  removal still carried out.
  """
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, IntakeEmailLog, IntakePayment}
  alias Dhc.DestinationBackfill
  alias Dhc.Notifications.Notification
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google, Recipients}
  alias Dhc.WorkshopCalendarHTTP, as: HTTP

  @now ~U[2026-10-22 12:00:00.000000Z]
  # 28 March 2027, 10:00–12:00 Dublin (09:00–11:00 UTC).
  @start ~U[2027-03-28 09:00:00Z]
  @ends_at ~U[2027-03-28 11:00:00Z]
  @location "National Basketball Arena, Tymon Park, Dublin 6w"

  @mapping %{
    "mappings" => [
      %{
        "venue" => "Club hall",
        "destination" => %{
          "destination_name" => "National Basketball Arena",
          "destination_address" => "Tymon Park, Dublin 6w",
          "directions_url" => "https://maps.app.goo.gl/AbCdEf"
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
      client_id: "bw-backfill-client",
      client_secret: "bw-backfill-secret",
      refresh_token: "bw-backfill-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> HTTP.initial() end})
    HTTP.stub(server)
    Stripe.stub_create()
    %{server: server, staff: Fixtures.staff_fixture()}
  end

  test "enrichment updates both existing events, keeps recipients and RSVPs, then stays silent",
       %{server: server, staff: staff} do
    {workshop, [{intake, token}]} = contacted!(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()

    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    original = participant(server)
    committee = committee(server)
    assert original["location"] == "Club hall"
    rsvp!(server, original, "accepted")
    recipients = Recipients.list(event_row(workshop.id, "participant"))
    before = HTTP.mutations(server)
    stored = Repo.get!(BeginnersWorkshop, workshop.id)
    logs = Repo.all(IntakeEmailLog)
    notifications = Repo.all(Notification)
    emails = all_enqueued(worker: Dhc.Email.Worker)

    assert %{results: [%{source_kind: :beginners_workshop, outcome: :changed}]} =
             apply!(staff, workshop)

    # No rescheduled Intake Email, log occasion or Staff Notification; only
    # the destination changed.
    assert Repo.all(IntakeEmailLog) == logs
    assert Repo.all(Notification) == notifications

    assert all_enqueued(worker: Dhc.Email.Worker) == emails

    enriched = Repo.get!(BeginnersWorkshop, workshop.id)
    kept = ~w(venue date start_time end_time payment_cutoff contact_from reschedule_count status)a
    assert Map.take(enriched, kept) == Map.take(stored, kept)

    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)

    updated = participant(server)
    assert updated["id"] == original["id"]
    assert updated["location"] == @location
    assert updated["start"] == original["start"]
    assert updated["end"] == original["end"]

    assert updated["attendees"] == [
             Map.put(hd(original["attendees"]), "responseStatus", "accepted")
           ]

    assert committee(server)["id"] == committee["id"]
    assert committee(server)["location"] == @location
    assert map_size(HTTP.events(server)) == 2
    refute Jason.encode!(HTTP.events(server)) =~ "maps.app.goo.gl"

    # A normal meaningful participant update (Google may email); committee
    # updates stay silent.
    new = HTTP.mutations(server) -- before
    assert Enum.any?(new, &(&1.query == "sendUpdates=all"))

    assert Enum.all?(new, fn m ->
             String.contains?(m.path, "participants") == (m.query == "sendUpdates=all")
           end)

    assert Recipients.list(event_row(workshop.id, "participant")) == recipients

    # Converged: neither audience updates again, and repeating the plan is a
    # no-op that records no further intent.
    settled = HTTP.mutations(server)
    assert :ok = sync(workshop.id, :committee)
    assert :ok = sync(workshop.id, :participant)
    assert HTTP.mutations(server) == settled

    revision = event_row(workshop.id, "committee").revision
    assert %{results: [%{outcome: :unchanged}]} = apply!(staff, workshop)
    assert event_row(workshop.id, "committee").revision == revision
  end

  test "inactive sending retains the change without Google, then converges on activation",
       %{server: server, staff: staff} do
    workshop = schedule!(staff)
    config = deactivate!()

    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)
    assert :ok = sync(workshop.id, :committee)
    assert HTTP.requests(server) == []

    activate!(config)
    assert :ok = sync(workshop.id, :committee)
    assert committee(server)["location"] == @location
  end

  test "outstanding place removal is still carried out with the new location",
       %{server: server, staff: staff} do
    {workshop, [{intake, token}]} = contacted!(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id, :participant)
    first = participant(server)
    assert [_] = first["attendees"]

    # The removal is recorded but not yet synchronized when enrichment lands.
    assert {:ok, _} = command(staff, {:cancel_with_refund, workshop.id, intake.id, %{}})
    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)

    assert :ok = sync(workshop.id, :participant)
    assert participant(server)["id"] == first["id"]
    assert participant(server)["attendees"] == []
    assert participant(server)["location"] == @location
  end

  test "an enrichment reaching Google only after the event ended changes no detail",
       %{server: server, staff: staff} do
    workshop = schedule!(staff)
    assert :ok = sync(workshop.id, :committee)
    assert %{results: [%{outcome: :changed}]} = apply!(staff, workshop)
    before = HTTP.mutations(server)

    assert :ok = sync(workshop.id, :committee, @ends_at)
    assert HTTP.mutations(server) == before
    assert committee(server)["location"] == "Club hall"

    # And an apply at or after the start is refused outright.
    later = schedule!(staff)

    assert %{results: [%{outcome: :refused, reason: :started}]} =
             apply!(staff, later, @start)
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

    # An already-applied plan has no proposed target left; re-approve the
    # workshop as it now is.
    if targets == [], do: apply_current!(staff, workshop, now), else: result
  end

  defp apply_current!(staff, workshop, now) do
    facts =
      BeginnersWorkshop
      |> Repo.get!(workshop.id)
      |> BeginnersWorkshops.DestinationEnrichment.facts()

    target =
      %{
        source_kind: "beginners_workshop",
        source_id: workshop.id,
        expected: Map.take(facts, [:label, :status, :date, :start_time, :end_time, :destination])
      }
      |> Jason.encode!()
      |> Jason.decode!()

    {:ok, result} =
      DestinationBackfill.apply_plan(
        %{"mapping" => @mapping, "approved_targets" => [target]},
        {:staff, staff},
        clock: fn -> now end
      )

    result
  end

  @schedule %{
    "date" => "2027-03-28",
    "start_time" => "10:00",
    "end_time" => "12:00",
    "venue" => "Club hall"
  }

  defp schedule!(staff), do: Fixtures.scheduled_fixture(staff, @schedule)
  defp contacted!(staff, count), do: Fixtures.contacted_fixture(staff, count, @schedule)

  defp command(staff, operation),
    do: BeginnersWorkshops.execute({:staff, staff}, operation, clock: Fixtures.clock(@now))

  defp complete(session),
    do:
      BeginnersWorkshops.execute(:stripe, {:complete_payment, session},
        clock: Fixtures.clock(@now)
      )

  defp hold!(intake, token) do
    assert {:ok, _} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Fixtures.clock(@now)
             )

    Repo.get_by!(IntakePayment, intake_id: intake.id)
  end

  defp rsvp!(server, event, status) do
    Agent.update(server, fn state ->
      current = Map.fetch!(state.events, event["id"])
      attendees = Enum.map(current["attendees"], &Map.put(&1, "responseStatus", status))
      sequence = state.sequence + 1
      replaced = current |> Map.put("attendees", attendees) |> Map.put("etag", "\"#{sequence}\"")
      %{state | events: Map.put(state.events, event["id"], replaced), sequence: sequence}
    end)
  end

  defp sync(id, audience, now \\ @now),
    do: WorkshopCalendar.sync(:beginners_workshop, id, audience: audience, clock: fn -> now end)

  defp event_row(id, audience),
    do: Repo.get_by(Event, source_kind: "beginners_workshop", source_id: id, audience: audience)

  defp participant(server),
    do: HTTP.events(server) |> Map.values() |> Enum.find(&Map.has_key?(&1, "attendees"))

  defp committee(server),
    do: HTTP.events(server) |> Map.values() |> Enum.reject(&Map.has_key?(&1, "attendees")) |> hd()
end
