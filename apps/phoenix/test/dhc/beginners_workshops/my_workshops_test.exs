defmodule Dhc.BeginnersWorkshops.MyWorkshopsTest do
  @moduledoc """
  ALE-379: the "My Beginners' Workshops" read model — the caller's upcoming
  and same-day assignments, soonest first, with their role — and the door
  view header with its assignment-scope resource.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops

  setup do
    coordinator = staff_fixture()
    %{coordinator: coordinator, coach: staff_fixture("coach"), member: staff_fixture("member")}
  end

  defp mine(principal_id, now \\ now()),
    do: BeginnersWorkshops.my_workshops(principal_id, clock: clock(now))

  defp schedule(ctx, date),
    do: scheduled_fixture(ctx.coordinator, %{"date" => date})

  describe "my_workshops/2" do
    test "lists the caller's upcoming assignments soonest first, with their role", ctx do
      later = schedule(ctx, "2026-11-21")
      sooner = schedule(ctx, "2026-11-14")
      _not_mine = schedule(ctx, "2026-11-07")

      set_staff!(later.id, ctx.coach, [ctx.member])
      set_staff!(sooner.id, nil, [ctx.coach])

      assert [
               %{id: sooner_id, role: "assistant", venue: "St. Andrew's Hall", stage: _},
               %{id: later_id, role: "coach", date: ~D[2026-11-21], start_time: ~T[18:30:00]}
             ] = mine(ctx.coach)

      assert {sooner_id, later_id} == {sooner.id, later.id}
      assert [%{id: ^later_id, role: "assistant"}] = mine(ctx.member)
      assert mine(ctx.coordinator) == []
    end

    test "keeps same-day assignments, even once finalised, and drops past and cancelled ones",
         ctx do
      today = schedule(ctx, "2026-11-14")
      cancelled = schedule(ctx, "2026-11-21")
      set_staff!(today.id, ctx.coach)
      set_staff!(cancelled.id, ctx.coach)
      force_status!(cancelled.id, "cancelled")

      on_the_day = ~U[2026-11-14 20:00:00Z]
      assert [%{id: id, stage: :check_in_open}] = mine(ctx.coach, on_the_day)
      assert id == today.id

      force_status!(today.id, "finalised")
      assert [%{status: "finalised", stage: :finalised}] = mine(ctx.coach, on_the_day)

      assert mine(ctx.coach, ~U[2026-11-15 09:00:00Z]) == []
    end

    test "an unassigned person no longer sees the workshop", ctx do
      workshop = schedule(ctx, "2026-11-14")
      set_staff!(workshop.id, ctx.coach)
      assert [_] = mine(ctx.coach)

      set_staff!(workshop.id, nil)
      assert mine(ctx.coach) == []
    end
  end

  describe "door_view/2" do
    test "is the header with its Staff, and the Staff as the assignment-scope resource", ctx do
      workshop = schedule(ctx, "2026-11-14")
      set_staff!(workshop.id, ctx.coach, [ctx.member])

      assert {:ok, view, %{assigned_principal_ids: assigned}} =
               BeginnersWorkshops.door_view(workshop.id, clock: clock())

      assert Enum.sort(assigned) == Enum.sort([ctx.coach, ctx.member])

      assert Map.keys(view) |> Enum.sort() ==
               ~w(alerts check_in date finalisation id people staff stage start_time status venue)a

      assert %{venue: "St. Andrew's Hall", date: ~D[2026-11-14], alerts: []} = view
      assert view.staff.coach.principal_id == ctx.coach
    end

    test "an unstaffed workshop carries the Unstaffed alert and nobody assigned", ctx do
      workshop = schedule(ctx, "2026-11-14")

      assert {:ok, %{alerts: [:unstaffed]}, %{assigned_principal_ids: []}} =
               BeginnersWorkshops.door_view(workshop.id, clock: clock())
    end

    test "an unknown or malformed id is not found" do
      assert {:error, :not_found} = BeginnersWorkshops.door_view(Ecto.UUID.generate())
      assert {:error, :not_found} = BeginnersWorkshops.door_view("nope")
    end
  end

  describe "staff_candidates/0" do
    test "lists active Members by name with coaches marked", ctx do
      _inactive = staff_fixture("coach", %{is_active: false})

      candidates = BeginnersWorkshops.staff_candidates()
      by_id = Map.new(candidates, &{&1.principal_id, &1})

      assert by_id[ctx.coach].coach
      refute by_id[ctx.member].coach
      refute by_id[ctx.coordinator].coach
      assert map_size(by_id) == 3
      assert Enum.map(candidates, & &1.name) == Enum.sort(Enum.map(candidates, & &1.name))
    end
  end
end
