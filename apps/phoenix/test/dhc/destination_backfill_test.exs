defmodule Dhc.DestinationBackfillTest do
  @moduledoc """
  ALE-443: the reviewed upcoming destination backfill workflow — mapping,
  read-only preview and explicit apply — through public source operations
  with real persistence and a fixed clock.
  """
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query
  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshopFixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Intake, IntakeEmailLog}
  alias Dhc.DestinationBackfill
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google}
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.Workshop

  @now ~U[2027-03-01 12:00:00Z]

  @arena %{
    "destination_name" => "National Basketball Arena",
    "destination_address" => "Tymon Park, Dublin 6w",
    "directions_url" => "https://maps.app.goo.gl/AbCdEf"
  }
  @arena_fields %{
    destination_name: "National Basketball Arena",
    destination_address: "Tymon Park, Dublin 6w",
    directions_url: "https://maps.app.goo.gl/AbCdEf",
    destination_place_id: nil
  }

  setup do
    previous = WorkshopCalendar.config()

    # Every Google request fails the test: neither operation may call Google.
    Req.Test.stub(Google, fn _conn -> flunk("the backfill must never call Google") end)

    Application.put_env(:dhc, WorkshopCalendar,
      active: false,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "backfill-client",
      client_secret: "backfill-secret",
      refresh_token: "backfill-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    :ok
  end

  describe "parse_mapping/1" do
    test "accepts reviewed manual destinations and normalizes them" do
      assert {:ok, mapping} =
               DestinationBackfill.parse_mapping(%{
                 "mappings" => [
                   %{
                     "venue" => "  Club hall ",
                     "note" => "Reviewed with the venue's booking page",
                     "destination" => Map.put(@arena, "directions_url", " ")
                   }
                 ]
               })

      assert [%{venue: "Club hall", destination: destination}] = mapping.entries
      assert destination == %{@arena_fields | directions_url: nil}
    end

    test "refuses provider identities, unknown keys, invalid links and empty destinations" do
      document = %{
        "mappings" => [
          %{"venue" => "A", "destination" => Map.put(@arena, "place_id", "ChIJ123")},
          %{"venue" => "B", "destination" => %{"directions_url" => "https://example.com/x"}},
          %{"venue" => "C", "destination" => %{"destination_name" => " "}},
          %{"venue" => " ", "destination" => @arena},
          %{"venue" => "D", "destination" => @arena, "first_result" => true},
          "not an entry"
        ],
        "registry" => true
      }

      assert {:error, issues} = DestinationBackfill.parse_mapping(document)
      ats = Enum.map(issues, & &1.at)

      for at <- ~w(mappings[0].destination mappings[1].destination mappings[2].destination
                   mappings[3].venue mappings[4] mappings[5] mapping) do
        assert at in ats
      end

      assert %{issue: "directions_url: Directions link must be a Google Maps link"} =
               Enum.find(issues, &(&1.at == "mappings[1].destination"))

      assert {:error, _} = DestinationBackfill.parse_mapping(%{"venues" => []})
    end

    test "names manual destinations only: a selected place is refused, an echoed null is not" do
      selected = Map.put(@arena, "destination_place_id", "ChIJ123")

      assert {:error, [%{at: "mappings[0].destination", issue: issue}]} =
               DestinationBackfill.parse_mapping(%{
                 "mappings" => [%{"venue" => "A", "destination" => selected}]
               })

      assert issue =~ "manual destinations only"

      assert {:ok, %{entries: [%{destination: %{destination_place_id: nil}}]}} =
               DestinationBackfill.parse_mapping(%{
                 "mappings" => [
                   %{
                     "venue" => "A",
                     "destination" => Map.put(@arena, "destination_place_id", nil)
                   }
                 ]
               })
    end
  end

  describe "preview/2" do
    test "reports every upcoming Workshop individually with its outcome and Calendar effect" do
      mapped = workshop!(location: "Club hall", status: "published")
      spaced = workshop!(location: "club   HALL", status: "planned")
      already = workshop!(Map.to_list(@arena_fields) ++ [location: "Club hall"])
      unmatched = workshop!(location: "Somewhere unreviewed")
      ambiguous = workshop!(location: "Main hall")
      conflicting = workshop!(location: "Main hall annex")
      different = workshop!(location: "Club hall", destination_address: "Other road")
      cancelled = workshop!(location: "Club hall", status: "cancelled")
      archived = workshop!(location: "Club hall", archived_at: ~U[2027-02-01 00:00:00Z])

      started =
        workshop!(
          location: "Club hall",
          start_date: DateTime.add(@now, -3600),
          end_date: DateTime.add(@now, 3600)
        )

      past =
        workshop!(
          location: "Club hall",
          start_date: ~U[2027-02-01 09:00:00Z],
          end_date: ~U[2027-02-01 11:00:00Z]
        )

      preview = DestinationBackfill.preview(mapping!(), clock: fn -> @now end)
      rows = Map.new(preview.workshops, &{&1.source_id, &1})

      refute Map.has_key?(rows, past.id)

      assert %{
               source_kind: :workshop,
               label: "Club hall",
               status: "published",
               date: ~D[2027-03-28],
               start_time: ~T[10:00:00],
               end_time: ~T[12:00:00],
               match: :mapped,
               outcome: :change,
               reason: nil,
               proposed_destination: @arena_fields,
               current_destination: %{destination_name: nil},
               calendar: %{
                 location_before: "Club hall",
                 location_after: "National Basketball Arena, Tymon Park, Dublin 6w",
                 effect: :retained_until_activation
               }
             } = rows[mapped.id]

      assert %{match: :mapped, outcome: :change} = rows[spaced.id]
      assert %{outcome: :unchanged, calendar: %{effect: :none}} = rows[already.id]

      assert %{match: :unmatched, outcome: :refused, reason: :unreviewed_venue} =
               rows[unmatched.id]

      assert %{match: :ambiguous, reason: :ambiguous_venue, proposed_destination: nil} =
               rows[ambiguous.id]

      assert %{match: :ambiguous, reason: :ambiguous_venue} = rows[conflicting.id]
      assert %{outcome: :refused, reason: :destination_conflict} = rows[different.id]
      assert %{outcome: :refused, reason: :cancelled} = rows[cancelled.id]
      assert %{outcome: :refused, reason: :archived} = rows[archived.id]
      assert %{outcome: :refused, reason: :started} = rows[started.id]

      assert Enum.sort(Enum.map(preview.proposed_targets, & &1.source_id)) ==
               Enum.sort([mapped.id, spaced.id])

      assert %{
               source_kind: :workshop,
               expected: %{
                 label: "Club hall",
                 status: "published",
                 date: ~D[2027-03-28],
                 start_time: ~T[10:00:00],
                 end_time: ~T[12:00:00],
                 destination: %{destination_name: nil}
               }
             } = Enum.find(preview.proposed_targets, &(&1.source_id == mapped.id))

      assert preview.calendar_sending_active == false
      # The output carries no recipient address.
      refute Jason.encode!(preview) =~ "@example.com"
    end

    test "names the update effect when Calendar sending is active" do
      config = deactivate!()
      activate!(Keyword.put(config, :active, true))
      workshop!(location: "Club hall")

      assert %{calendar_sending_active: true, workshops: [row]} =
               DestinationBackfill.preview(mapping!(), clock: fn -> @now end)

      assert row.calendar.effect == :update_existing_events
    end

    test "writes nothing: no source, Calendar or job rows change" do
      workshop!(location: "Club hall", status: "published")
      workshop!(location: "Main hall")
      beginners!(BeginnersWorkshopFixtures.staff_fixture())
      before = snapshot()

      _preview = DestinationBackfill.preview(mapping!(), clock: fn -> @now end)

      assert snapshot() == before
    end
  end

  describe "apply_plan/3" do
    setup do
      %{staff: staff!()}
    end

    test "applies exactly the approved targets and reports newly discovered matches",
         %{staff: staff} do
      approved = workshop!(location: "Club hall", status: "published")
      left_alone = workshop!(location: "Club hall", status: "planned")
      preview = DestinationBackfill.preview(mapping!(), clock: fn -> @now end)

      plan = plan(preview, [approved.id])
      discovered = workshop!(location: "CLUB HALL")

      assert {:ok, result} = DestinationBackfill.apply_plan(plan, {:staff, staff}, clock: clock())

      assert result.results == [
               %{source_kind: :workshop, source_id: approved.id, outcome: :changed, reason: nil}
             ]

      assert result.summary == %{changed: 1}

      assert Enum.sort(Enum.map(result.discovered, & &1.source_id)) ==
               Enum.sort([left_alone.id, discovered.id])

      assert destination(approved.id) == @arena_fields
      assert destination(left_alone.id).destination_name == nil
      assert destination(discovered.id).destination_name == nil

      # Repeating the same plan is a no-op: no write and no Calendar intent.
      jobs = jobs()
      events = Repo.all(from(e in Event, order_by: e.id))
      row = Repo.get!(Workshop, approved.id)

      assert {:ok, %{results: [%{outcome: :unchanged}]}} =
               DestinationBackfill.apply_plan(plan, {:staff, staff}, clock: clock())

      fresh = plan(DestinationBackfill.preview(mapping!(), clock: clock()), [])

      fresh = %{
        fresh
        | "approved_targets" => [
            reviewed_target(approved.id, Repo.get!(Workshop, approved.id))
          ]
      }

      assert {:ok, %{results: [%{outcome: :unchanged}]}} =
               DestinationBackfill.apply_plan(fresh, {:staff, staff}, clock: clock())

      assert jobs() == jobs
      assert Repo.all(from(e in Event, order_by: e.id)) == events
      assert Repo.get!(Workshop, approved.id) == row
    end

    test "refuses unreviewed, ambiguous, duplicate, malformed and stale targets per target",
         %{staff: staff} do
      ok = workshop!(location: "Club hall", status: "published")
      ambiguous = workshop!(location: "Main hall")
      unreviewed = workshop!(location: "Elsewhere")
      rescheduled = workshop!(location: "Club hall")
      preview = DestinationBackfill.preview(mapping!(), clock: clock())

      {:ok, _} =
        Workshops.update_workshop(rescheduled.id, %{
          start_date: ~U[2027-03-28 10:00:00Z],
          end_date: ~U[2027-03-28 12:00:00Z]
        })

      targets =
        [
          reviewed_target(ok.id, ok),
          reviewed_target(ok.id, ok),
          reviewed_target(ambiguous.id, ambiguous),
          reviewed_target(unreviewed.id, unreviewed),
          target_for(preview, rescheduled.id),
          # A target may not carry its own destination.
          Map.put(reviewed_target(ok.id, ok), "destination", @arena),
          %{reviewed_target(ok.id, ok) | "source_kind" => "training_session"},
          %{reviewed_target(ok.id, ok) | "source_id" => "not-a-uuid"},
          "nonsense"
        ]

      plan = %{"mapping" => mapping_document(), "approved_targets" => targets}

      assert {:ok, %{results: results}} =
               DestinationBackfill.apply_plan(plan, {:staff, staff}, clock: clock())

      assert Enum.map(results, &{&1.outcome, &1.reason}) == [
               {:changed, nil},
               {:refused, :duplicate_target},
               {:refused, :ambiguous_venue},
               {:refused, :unreviewed_venue},
               {:refused, :rescheduled},
               {:refused, :invalid_target},
               {:refused, :invalid_target},
               {:refused, :invalid_target},
               {:refused, :invalid_target}
             ]

      assert destination(rescheduled.id).destination_name == nil
      assert destination(ambiguous.id).destination_name == nil
    end

    test "an unauthorized operator changes nothing" do
      workshop = workshop!(location: "Club hall")
      member = WorkshopFixtures.member_fixture()
      plan = plan(DestinationBackfill.preview(mapping!(), clock: clock()), [workshop.id])

      assert {:ok, %{results: [%{outcome: :refused, reason: :forbidden}]}} =
               DestinationBackfill.apply_plan(plan, {:staff, member.principal_id}, clock: clock())

      assert destination(workshop.id).destination_name == nil
    end

    test "a malformed plan or mapping is refused as a whole", %{staff: staff} do
      assert {:error, [%{at: "plan"}]} = DestinationBackfill.apply_plan(%{}, {:staff, staff})

      assert {:error, [%{at: "mappings[0]"} | _]} =
               DestinationBackfill.apply_plan(
                 %{"mapping" => %{"mappings" => [1]}, "approved_targets" => []},
                 {:staff, staff}
               )

      assert {:error, [%{at: "plan", issue: "unknown key proposed_targets"}]} =
               DestinationBackfill.apply_plan(
                 %{
                   "mapping" => mapping_document(),
                   "approved_targets" => [],
                   "proposed_targets" => []
                 },
                 {:staff, staff}
               )
    end
  end

  describe "Beginners' Workshops alongside Workshops (ALE-444)" do
    setup do
      %{staff: staff!(["workshop_coordinator", "beginners_coordinator"])}
    end

    test "preview reports each source kind individually, colliding ids and shared text included",
         %{staff: staff} do
      bw = beginners!(staff)
      twin = colliding_workshop!(bw.id, location: "Club hall", status: "published")
      spaced = beginners!(staff, %{"venue" => "CLUB  hall"})
      ambiguous = beginners!(staff, %{"venue" => "Main hall"})
      unmatched = beginners!(staff, %{"venue" => "Somewhere unreviewed"})
      cancelled = beginners!(staff)
      assert {:ok, _} = bw_run(staff, {:cancel_workshop, cancelled.id, %{}})
      finalised = beginners!(staff)
      BeginnersWorkshopFixtures.force_status!(finalised.id, "finalised")
      past = beginners!(staff, %{"date" => "2027-02-01"})

      preview = DestinationBackfill.preview(mapping!(), clock: clock())

      assert %{
               source_kind: :beginners_workshop,
               source_id: id,
               title: "Beginners' Workshop",
               label: "Club hall",
               status: "scheduled",
               archived: false,
               starts_at: ~U[2027-03-28 09:00:00Z],
               ends_at: ~U[2027-03-28 11:00:00Z],
               date: ~D[2027-03-28],
               start_time: ~T[10:00:00],
               end_time: ~T[12:00:00],
               match: :mapped,
               outcome: :change,
               current_destination: %{destination_name: nil},
               proposed_destination: @arena_fields,
               calendar: %{
                 location_before: "Club hall",
                 location_after: "National Basketball Arena, Tymon Park, Dublin 6w",
                 effect: :retained_until_activation
               }
             } = row(preview, :beginners_workshop, bw.id)

      assert id == twin.id

      assert %{source_kind: :workshop, status: "published", outcome: :change} =
               row(preview, :workshop, twin.id)

      assert %{match: :mapped, outcome: :change} = row(preview, :beginners_workshop, spaced.id)

      assert %{match: :ambiguous, reason: :ambiguous_venue} =
               row(preview, :beginners_workshop, ambiguous.id)

      assert %{reason: :unreviewed_venue} = row(preview, :beginners_workshop, unmatched.id)

      assert %{outcome: :refused, reason: :cancelled} =
               row(preview, :beginners_workshop, cancelled.id)

      assert %{outcome: :refused, reason: :not_eligible_status} =
               row(preview, :beginners_workshop, finalised.id)

      refute row(preview, :beginners_workshop, past.id)

      targets = Enum.map(preview.proposed_targets, &{&1.source_kind, &1.source_id})

      assert Enum.sort(targets) ==
               Enum.sort([
                 {:beginners_workshop, bw.id},
                 {:workshop, twin.id},
                 {:beginners_workshop, spaced.id}
               ])
    end

    test "preview carries no person, address or Intake link data", %{staff: staff} do
      {workshop, intakes} =
        BeginnersWorkshopFixtures.contacted_fixture(staff, 2, %{
          "date" => "2027-03-28",
          "venue" => "Club hall"
        })

      json = mapping!() |> DestinationBackfill.preview(clock: clock()) |> Jason.encode!()

      assert json =~ workshop.id
      refute json =~ "waitlist.example.com"
      refute json =~ "/beginners/intake/"

      for {intake, token} <- intakes do
        refute json =~ intake.id
        refute json =~ token
      end
    end

    test "apply changes exactly the approved targets, keyed by source kind", %{staff: staff} do
      bw = beginners!(staff)
      twin = colliding_workshop!(bw.id, location: "Club hall", status: "published")
      other = beginners!(staff)
      preview = DestinationBackfill.preview(mapping!(), clock: clock())

      only_bw =
        preview
        |> plan([bw.id])
        |> Map.update!("approved_targets", fn targets ->
          Enum.filter(targets, &(&1["source_kind"] == "beginners_workshop"))
        end)

      assert {:ok, result} =
               DestinationBackfill.apply_plan(only_bw, {:staff, staff}, clock: clock())

      assert result.results == [
               %{
                 source_kind: :beginners_workshop,
                 source_id: bw.id,
                 outcome: :changed,
                 reason: nil
               }
             ]

      assert destination(:beginners_workshop, bw.id) == @arena_fields
      # The regular twin with the same id and text is untouched and still owed.
      assert destination(twin.id).destination_name == nil
      assert destination(:beginners_workshop, other.id).destination_name == nil

      assert Enum.sort(Enum.map(result.discovered, &{&1.source_kind, &1.source_id})) ==
               Enum.sort([{:workshop, twin.id}, {:beginners_workshop, other.id}])

      # The same id twice under one kind is a duplicate; under two kinds it is not.
      both = plan(preview, [bw.id])

      [bw_target] =
        Enum.filter(both["approved_targets"], &(&1["source_kind"] == "beginners_workshop"))

      both = %{both | "approved_targets" => both["approved_targets"] ++ [bw_target]}

      assert {:ok, %{results: results}} =
               DestinationBackfill.apply_plan(both, {:staff, staff}, clock: clock())

      assert Enum.sort(Enum.map(results, &{&1.source_kind, &1.outcome, &1.reason})) ==
               Enum.sort([
                 {:workshop, :changed, nil},
                 {:beginners_workshop, :unchanged, nil},
                 {:beginners_workshop, :refused, :duplicate_target}
               ])

      assert destination(twin.id) == @arena_fields
    end

    test "a mixed run reports per target after real changes between preview and apply",
         %{staff: staff} do
      changed = beginners!(staff)
      rescheduled = beginners!(staff)
      moved = beginners!(staff)
      cancelled = beginners!(staff)
      edited = beginners!(staff)
      regular = workshop!(location: "Club hall", status: "published")
      preview = DestinationBackfill.preview(mapping!(), clock: clock())

      times = %{"start_time" => "11:00", "end_time" => "13:00"}
      assert {:ok, _} = bw_run(staff, {:reschedule_workshop, rescheduled.id, times})

      assert {:ok, _} =
               bw_run(
                 staff,
                 {:reschedule_workshop, moved.id,
                  %{"start_time" => "10:00", "end_time" => "12:00", "venue" => "The Hub"}}
               )

      assert {:ok, _} = bw_run(staff, {:cancel_workshop, cancelled.id, %{}})

      assert {:ok, _} =
               bw_run(
                 staff,
                 {:update_destination, edited.id,
                  %{"venue" => "Club hall", "destination_address" => "Elsewhere"}}
               )

      plan =
        plan(preview, [changed.id, rescheduled.id, moved.id, cancelled.id, edited.id, regular.id])

      assert {:ok, %{results: results}} =
               DestinationBackfill.apply_plan(plan, {:staff, staff}, clock: clock())

      outcomes = Map.new(results, &{&1.source_id, {&1.source_kind, &1.outcome, &1.reason}})

      assert outcomes == %{
               changed.id => {:beginners_workshop, :changed, nil},
               rescheduled.id => {:beginners_workshop, :refused, :rescheduled},
               moved.id => {:beginners_workshop, :refused, :label_changed},
               cancelled.id => {:beginners_workshop, :refused, :cancelled},
               edited.id => {:beginners_workshop, :refused, :destination_changed},
               regular.id => {:workshop, :changed, nil}
             }

      for workshop <- [rescheduled, moved, cancelled],
          do: assert(destination(:beginners_workshop, workshop.id).destination_name == nil)

      assert destination(:beginners_workshop, edited.id).destination_address == "Elsewhere"
    end

    test "the start boundary is judged at apply time", %{staff: staff} do
      bw = beginners!(staff)
      plan = plan(DestinationBackfill.preview(mapping!(), clock: clock()), [bw.id])
      start = ~U[2027-03-28 09:00:00Z]

      assert {:ok, %{results: [%{outcome: :refused, reason: :started}]}} =
               DestinationBackfill.apply_plan(plan, {:staff, staff}, clock: fn -> start end)

      assert {:ok, %{results: [%{outcome: :changed}]}} =
               DestinationBackfill.apply_plan(plan, {:staff, staff},
                 clock: fn -> DateTime.add(start, -1) end
               )
    end

    test "each target is authorized by its own owner", %{staff: coordinator} do
      bw = beginners!(coordinator)
      regular = workshop!(location: "Club hall", status: "published")
      workshops_only = staff!()
      plan = plan(DestinationBackfill.preview(mapping!(), clock: clock()), [bw.id, regular.id])

      assert {:ok, %{results: results}} =
               DestinationBackfill.apply_plan(plan, {:staff, workshops_only}, clock: clock())

      assert Enum.sort(Enum.map(results, &{&1.source_kind, &1.outcome, &1.reason})) ==
               [{:beginners_workshop, :refused, :forbidden}, {:workshop, :changed, nil}]

      assert destination(:beginners_workshop, bw.id).destination_name == nil
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp clock, do: fn -> @now end

  defp mapping_document do
    %{
      "mappings" => [
        %{"venue" => "Club hall", "destination" => @arena},
        %{"venue" => "Main hall annex", "destination" => @arena},
        %{"venue" => "Main hall annex", "destination" => Map.put(@arena, "directions_url", nil)}
      ],
      "ambiguous" => ["Main hall"]
    }
  end

  defp mapping! do
    {:ok, mapping} = DestinationBackfill.parse_mapping(mapping_document())
    mapping
  end

  # The operator's plan exactly as the JSON round trip delivers it.
  defp plan(preview, approved_ids) do
    preview = preview |> Jason.encode!() |> Jason.decode!()

    %{
      "mapping" => preview["mapping"],
      "approved_targets" =>
        Enum.filter(preview["proposed_targets"], &(&1["source_id"] in approved_ids))
    }
  end

  defp target_for(preview, id) do
    preview.proposed_targets
    |> Enum.find(&(&1.source_id == id))
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp reviewed_target(id, workshop) do
    facts = Dhc.Workshops.DestinationEnrichment.facts(workshop)

    %{
      source_kind: "workshop",
      source_id: id,
      expected: Map.take(facts, [:label, :status, :date, :start_time, :end_time, :destination])
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp workshop!(attrs) do
    {archived_at, attrs} = Keyword.pop(attrs, :archived_at)

    workshop =
      [start_date: ~U[2027-03-28 09:00:00Z], end_date: ~U[2027-03-28 11:00:00Z]]
      |> Keyword.merge(attrs)
      |> WorkshopFixtures.workshop_fixture()

    if archived_at,
      do: workshop |> Ecto.Changeset.change(archived_at: archived_at) |> Repo.update!(),
      else: workshop
  end

  defp staff!(roles \\ ["workshop_coordinator"]) do
    member = WorkshopFixtures.member_fixture()

    for role <- ["member" | roles],
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end

  defp destination(id),
    do: Workshop |> Repo.get!(id) |> Map.take(Map.keys(@arena_fields))

  defp destination(:beginners_workshop, id),
    do: BeginnersWorkshop |> Repo.get!(id) |> Map.take(Map.keys(@arena_fields))

  # A Beginners' Workshop on the regular Workshops' date, 10:00–12:00 Dublin
  # (09:00–11:00 UTC), scheduled through its own boundary.
  defp beginners!(coordinator, overrides \\ %{}) do
    BeginnersWorkshopFixtures.scheduled_fixture(
      coordinator,
      Map.merge(
        %{
          "date" => "2027-03-28",
          "start_time" => "10:00",
          "end_time" => "12:00",
          "venue" => "Club hall"
        },
        overrides
      )
    )
  end

  defp bw_run(staff, command),
    do: BeginnersWorkshops.execute({:staff, staff}, command, clock: Clock.fixed(@now))

  # A regular Workshop that shares a Beginners' Workshop's id: the tables are
  # separate, so only `{source_kind, source_id}` tells them apart.
  defp colliding_workshop!(id, attrs) do
    workshop = workshop!(attrs)
    Repo.update_all(from(w in Workshop, where: w.id == ^workshop.id), set: [id: id])
    Repo.get!(Workshop, id)
  end

  defp row(preview, kind, id),
    do: Enum.find(preview.workshops, &(&1.source_kind == kind and &1.source_id == id))

  defp jobs, do: Repo.all(from(j in Oban.Job, order_by: j.id, select: j.id))

  defp snapshot do
    %{
      workshops: Repo.all(from(w in Workshop, order_by: w.id)),
      beginners_workshops: Repo.all(from(w in BeginnersWorkshop, order_by: w.id)),
      intakes: Repo.all(from(i in Intake, order_by: i.id)),
      intake_email_logs: Repo.all(from(l in IntakeEmailLog, order_by: l.id)),
      events: Repo.all(from(e in Event, order_by: e.id)),
      jobs: jobs()
    }
  end
end
