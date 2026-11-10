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
    directions_url: "https://maps.app.goo.gl/AbCdEf"
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
          %{reviewed_target(ok.id, ok) | "source_kind" => "beginners_workshop"},
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

  defp staff! do
    member = WorkshopFixtures.member_fixture()

    for role <- ["member", "workshop_coordinator"],
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end

  defp destination(id),
    do: Workshop |> Repo.get!(id) |> Map.take(Map.keys(@arena_fields))

  defp jobs, do: Repo.all(from(j in Oban.Job, order_by: j.id, select: j.id))

  defp snapshot do
    %{
      workshops: Repo.all(from(w in Workshop, order_by: w.id)),
      events: Repo.all(from(e in Event, order_by: e.id)),
      jobs: jobs()
    }
  end
end
