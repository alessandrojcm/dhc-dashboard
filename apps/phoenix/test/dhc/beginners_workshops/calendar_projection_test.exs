defmodule Dhc.BeginnersWorkshops.CalendarProjectionTest do
  use Dhc.DataCase, async: true

  import Ecto.Query
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.BeginnersWorkshop
  alias Dhc.Repo

  describe "calendar_projection/1" do
    test "returns only Calendar-safe workshop fields in Dublin instants" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator, %{"venue" => "Main hall"})

      assert %{
               id: id,
               title: "Beginners' Workshop",
               status: "scheduled",
               start_date: ~U[2026-11-14 18:30:00Z],
               end_date: ~U[2026-11-14 20:30:00Z],
               location: "Main hall"
             } = BeginnersWorkshops.calendar_projection(workshop.id)

      assert id == workshop.id
      refute Map.has_key?(BeginnersWorkshops.calendar_projection(workshop.id), :capacity)
      assert BeginnersWorkshops.calendar_projection(Ecto.UUID.generate()) == nil
    end

    test "keeps a missing or invalid end time unknown rather than guessing" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator)

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id),
        set: [end_time: nil]
      )

      assert %{start_date: ~U[2026-11-14 18:30:00Z], end_date: nil} =
               BeginnersWorkshops.calendar_projection(workshop.id)

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id),
        set: [end_time: ~T[18:00:00]]
      )

      assert %{start_date: ~U[2026-11-14 18:30:00Z], end_date: nil} =
               BeginnersWorkshops.calendar_projection(workshop.id)
    end

    test "presents finalised workshops as scheduled and preserves cancellation" do
      coordinator = staff_fixture()
      finalised = scheduled_fixture(coordinator)
      cancelled = scheduled_fixture(coordinator)

      force_status!(finalised.id, "finalised")
      force_status!(cancelled.id, "cancelled")

      assert %{status: "scheduled"} = BeginnersWorkshops.calendar_projection(finalised.id)
      assert %{status: "cancelled"} = BeginnersWorkshops.calendar_projection(cancelled.id)
    end
  end

  describe "calendar_source_ids/1" do
    test "keeps current sources, cancelled history, and upcoming unknown ends discoverable" do
      coordinator = staff_fixture()
      now = ~U[2026-11-14 19:00:00Z]

      in_progress = scheduled_fixture(coordinator)
      finalised = scheduled_fixture(coordinator)
      cancelled = scheduled_fixture(coordinator)
      missing_end = scheduled_fixture(coordinator, %{"date" => "2026-11-15"})
      past = scheduled_fixture(coordinator, %{"date" => "2026-11-13"})

      force_status!(finalised.id, "finalised")
      force_status!(cancelled.id, "cancelled")

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^missing_end.id),
        set: [end_time: nil]
      )

      ids = BeginnersWorkshops.calendar_source_ids(now)

      assert in_progress.id in ids
      assert finalised.id in ids
      assert cancelled.id in ids
      assert missing_end.id in ids
      refute past.id in ids
    end
  end
end
