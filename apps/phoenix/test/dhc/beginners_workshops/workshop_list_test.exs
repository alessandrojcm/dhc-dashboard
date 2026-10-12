defmodule Dhc.BeginnersWorkshops.WorkshopListTest do
  @moduledoc """
  ALE-378: the Workshops list read model — grouping and order, and the
  stage, seat meter and alerts each row carries — read through
  `Dhc.BeginnersWorkshops.list_workshops/1` at a fixed clock.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, WorkshopFacts, WorkshopPolicy}

  defp list(now \\ now()), do: BeginnersWorkshops.list_workshops(clock: Clock.fixed(now))

  test "upcoming workshops first, soonest first; then past and cancelled, most recent first" do
    staff = staff_fixture()
    late = scheduled_fixture(staff, %{"date" => "2026-12-05"})
    soon = scheduled_fixture(staff, %{"date" => "2026-11-14"})
    finalised = scheduled_fixture(staff, %{"date" => "2026-10-24"})
    cancelled = scheduled_fixture(staff, %{"date" => "2026-11-07"})
    force_status!(finalised.id, "finalised")
    force_status!(cancelled.id, "cancelled")

    assert %{upcoming: upcoming, past: past} = list()
    assert Enum.map(upcoming, & &1.id) == [soon.id, late.id]
    assert Enum.map(past, & &1.id) == [cancelled.id, finalised.id]
    assert Enum.map(past, & &1.stage) == [:cancelled, :finalised]
  end

  test "each row has its date, stage, seat meter and alerts" do
    staff = staff_fixture()
    scheduled_fixture(staff, %{"capacity" => 12})

    assert %{upcoming: [row], past: []} = list()

    assert %{
             date: ~D[2026-11-14],
             start_time: ~T[18:30:00],
             stage: :next_batch_due,
             seats: %{capacity: 12, paid: 0, holds: 0, free: 12},
             alerts: [:unstaffed]
           } = row
  end

  test "a Beginners' Workshop is never a Workshop, so no Workshop read can list or announce it" do
    scheduled_fixture(staff_fixture())

    # The member calendar, the public listing, Member Announcements and
    # Discord announcements all read Workshop storage (`club_activities`).
    assert Dhc.Repo.aggregate(Dhc.Workshops.Workshop, :count) == 0
    assert %{upcoming: [_]} = list()
  end

  test "an empty list has both groups" do
    assert list() == %{upcoming: [], past: []}
  end

  describe "stages of a scheduled workshop" do
    # 14 Nov 2026 18:30 Dublin (GMT) start, cutoff 11 Nov 18:30, contact from 20 Oct.
    setup do
      staff = staff_fixture()
      %{workshop: scheduled_fixture(staff, %{"contact_from" => "2026-10-20"})}
    end

    for {label, now, stage} <- [
          {"before the contact-from date", ~U[2026-10-19 12:00:00Z], :before_contact_from},
          {"before 10:00 on the contact-from date", ~U[2026-10-20 08:59:00Z],
           :before_contact_from},
          {"10:00 on the contact-from date", ~U[2026-10-20 09:00:00Z], :next_batch_due},
          {"at the Payment Cutoff", ~U[2026-11-11 18:30:00Z], :payment_closed},
          {"the day, before check-in opens", ~U[2026-11-14 17:29:00Z], :today_before_check_in},
          {"an hour before the start", ~U[2026-11-14 17:30:00Z], :check_in_open},
          {"the day after", ~U[2026-11-15 09:00:00Z], :awaiting_finalisation}
        ] do
      test "#{label} → #{stage}" do
        assert %{upcoming: [%{stage: unquote(stage)}]} = list(unquote(Macro.escape(now)))
      end
    end
  end

  describe "WorkshopPolicy.stage/3 with facts later tickets supply" do
    setup do
      workshop = %BeginnersWorkshop{
        status: "scheduled",
        date: ~D[2026-11-14],
        start_time: ~T[18:30:00],
        capacity: 4,
        payment_cutoff: ~U[2026-11-11 18:30:00Z],
        contact_from: ~D[2026-10-20]
      }

      %{workshop: workshop, reading: Clock.read(Clock.fixed(~U[2026-10-25 12:00:00Z]))}
    end

    test "full, paused and an open window", %{workshop: w, reading: reading} do
      facts = WorkshopFacts.empty()
      assert WorkshopPolicy.stage(w, %{facts | paid: 4}, reading) == :full
      assert WorkshopPolicy.stage(w, %{facts | batches_paused: true}, reading) == :batches_paused

      open = %{facts | batches_sent: 1, latest_window_end: ~U[2026-10-27 23:59:00Z]}
      assert WorkshopPolicy.stage(w, open, reading) == :window_open

      assert WorkshopPolicy.stage(
               w,
               %{open | latest_window_end: ~U[2026-10-24 23:59:00Z]},
               reading
             ) ==
               :next_batch_due
    end

    test "seats count paid and live holds; a workshop with any Staff (even no coach) has no alert",
         %{workshop: w} do
      staff = %{coach: nil, assistants: [%{principal_id: Ecto.UUID.generate(), name: "Asha"}]}
      facts = %{WorkshopFacts.empty() | paid: 2, holds: 1, staff: staff}

      assert WorkshopPolicy.seats(w, facts) == %{
               capacity: 4,
               paid: 2,
               holds: 1,
               free: 1,
               attended: 0,
               no_show: 0
             }

      assert WorkshopPolicy.alerts(w, facts) == []
      assert WorkshopPolicy.alerts(%{w | status: "cancelled"}, WorkshopFacts.empty()) == []
    end
  end
end
