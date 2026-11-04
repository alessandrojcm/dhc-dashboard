defmodule Dhc.Workshops.CalendarProjectionTest do
  use Dhc.DataCase, async: true

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  describe "calendar_projection/1" do
    test "returns only Calendar-safe Workshop fields, including archived sources" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          title: "Calendar Workshop",
          description: "Do not expose this",
          location: "Main hall",
          status: "published"
        )

      {:ok, _} =
        workshop
        |> Ecto.Changeset.change(archived_at: ~U[2026-11-04 10:00:00Z])
        |> Repo.update()

      assert %{
               id: id,
               title: "Calendar Workshop",
               status: "published",
               start_date: start_date,
               end_date: end_date,
               location: "Main hall"
             } = Workshops.calendar_projection(workshop.id)

      assert id == workshop.id
      assert %DateTime{} = start_date
      assert %DateTime{} = end_date
      refute Map.has_key?(Workshops.calendar_projection(workshop.id), :description)
      assert Workshops.calendar_projection(Ecto.UUID.generate()) == nil
    end
  end

  describe "calendar_source_ids/1" do
    test "includes upcoming archived sources and cancelled historical sources" do
      now = ~U[2026-11-04 12:00:00Z]

      upcoming_archived =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.add(now, 86_400, :second),
          end_date: DateTime.add(now, 93_600, :second),
          status: "published"
        )

      {:ok, _} =
        upcoming_archived
        |> Ecto.Changeset.change(archived_at: now)
        |> Repo.update()

      cancelled_past =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.add(now, -172_800, :second),
          end_date: DateTime.add(now, -165_600, :second),
          status: "cancelled"
        )

      historical_finished =
        WorkshopFixtures.workshop_fixture(
          start_date: DateTime.add(now, -172_800, :second),
          end_date: DateTime.add(now, -165_600, :second),
          status: "finished"
        )

      ids = Workshops.calendar_source_ids(now)

      assert upcoming_archived.id in ids
      assert cancelled_past.id in ids
      refute historical_finished.id in ids
    end
  end
end
