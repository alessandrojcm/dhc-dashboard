defmodule Dhc.BeginnersWorkshops.EndTimeTest do
  use Dhc.DataCase, async: true

  import Ecto.Query
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, IntakeEmailLog}
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  describe "schedule_workshop" do
    test "requires an explicit later Dublin civil end time" do
      coordinator = staff_fixture()

      assert {:error, {:workshop, 0, changeset}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:schedule_workshop, [Map.delete(workshop_attrs(), "end_time")]},
                 clock: clock()
               )

      assert %{end_time: ["can't be blank"]} = errors_on(changeset)

      for end_time <- ["18:30", "18:29"] do
        assert {:error, {:workshop, 0, :invalid_end_time}} =
                 BeginnersWorkshops.execute(
                   {:staff, coordinator},
                   {:schedule_workshop, [workshop_attrs(%{"end_time" => end_time})]},
                   clock: clock()
                 )
      end

      assert {:error, {:workshop, 0, changeset}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:schedule_workshop, [workshop_attrs(%{"end_time" => "not-a-time"})]},
                 clock: clock()
               )

      assert %{end_time: [_]} = errors_on(changeset)
    end

    test "accepts later civil times across winter, summer and autumn Dublin dates" do
      coordinator = staff_fixture()

      for {date, start_time, end_time} <- [
            {"2026-12-12", "18:30", "20:30"},
            {"2027-06-12", "18:30", "20:30"},
            {"2027-10-31", "02:30", "03:30"}
          ] do
        assert {:ok, [%{date: scheduled_date, start_time: start, end_time: ending}]} =
                 BeginnersWorkshops.execute(
                   {:staff, coordinator},
                   {:schedule_workshop,
                    [
                      workshop_attrs(%{
                        "date" => date,
                        "start_time" => start_time,
                        "end_time" => end_time
                      })
                    ]},
                   clock: clock()
                 )

        assert Date.to_iso8601(scheduled_date) == date
        assert Calendar.strftime(start, "%H:%M") == start_time
        assert Calendar.strftime(ending, "%H:%M") == end_time
      end
    end

    test "uses Dublin DST conversion when validating a spring-forward schedule" do
      coordinator = staff_fixture()

      attrs =
        workshop_attrs(%{
          "date" => "2027-03-28",
          "start_time" => "01:30",
          "end_time" => "02:00"
        })

      assert {:error, {:workshop, 0, :invalid_end_time}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:schedule_workshop, [attrs]},
                 clock: Clock.fixed(~U[2026-10-09 11:00:00Z])
               )
    end
  end

  describe "reschedule_workshop" do
    test "explicit unchanged start times still allow venue and end-time corrections after the start" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator)
      during_workshop = Clock.fixed(~U[2026-11-14 19:30:00Z])

      assert {:ok, %{venue: "The Hub", start_time: ~T[18:30:00]}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:reschedule_workshop, workshop.id,
                  %{"venue" => "The Hub", "start_time" => "18:30", "end_time" => "20:30"}},
                 clock: during_workshop
               )

      assert {:ok, %{end_time: ~T[21:00:00]}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:reschedule_workshop, workshop.id,
                  %{"start_time" => "18:30", "end_time" => "21:00"}},
                 clock: during_workshop
               )

      assert {:error, :start_in_past} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:reschedule_workshop, workshop.id,
                  %{"start_time" => "19:00", "end_time" => "21:00"}},
                 clock: during_workshop
               )
    end

    test "requires both explicit times, including for a venue-only move" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator)

      assert {:error, changeset} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:reschedule_workshop, workshop.id, %{"venue" => "The Hub"}},
                 clock: clock()
               )

      assert %{start_time: ["can't be blank"], end_time: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "changes both times explicitly without altering the cutoff or contact schedule" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20"})

      assert {:ok, view} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:reschedule_workshop, workshop.id,
                  %{"date" => "2026-11-21", "start_time" => "19:00", "end_time" => "21:00"}},
                 clock: clock()
               )

      assert %{start_time: ~T[19:00:00], end_time: ~T[21:00:00]} = view
      assert view.payment_cutoff == ~U[2026-11-18 19:00:00.000000Z]
      assert view.contact_from == ~D[2026-10-27]
      assert %{reschedule_count: 1} = Repo.get!(BeginnersWorkshop, workshop.id)
    end
  end

  describe "legacy end times" do
    test "remain readable, are reported for upcoming backfill, and can be filled through the boundary" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator)
      id = workshop.id

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^id),
        set: [end_time: nil]
      )

      assert %{upcoming: [%{id: ^id, end_time: nil}]} =
               BeginnersWorkshops.list_workshops(clock: clock())

      assert [%{id: ^id, end_time: nil, issue: :missing}] =
               BeginnersWorkshops.end_time_report(clock: clock())

      assert {:ok, %{end_time: ~T[20:30:00]}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, workshop.id, %{"end_time" => "20:30"}},
                 clock: clock()
               )

      assert BeginnersWorkshops.end_time_report(clock: clock()) == []
      assert %{end_time: ~T[20:30:00]} = Repo.get!(BeginnersWorkshop, id)
    end

    test "backfill is authorized, only fills unknown upcoming scheduled rows, and leaves schedule policy alone" do
      coordinator = staff_fixture()
      member = Dhc.MemberFixtures.member_fixture().principal_id
      workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20"})
      id = workshop.id

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^id), set: [end_time: nil])
      before = Repo.get!(BeginnersWorkshop, id)
      emails_before = Repo.aggregate(IntakeEmailLog, :count)
      notifications_before = Repo.aggregate(Notification, :count)

      for actor <- [{:staff, member}, :system] do
        assert {:error, :forbidden} =
                 BeginnersWorkshops.execute(
                   actor,
                   {:backfill_end_time, id, %{"end_time" => "20:30"}},
                   clock: clock()
                 )
      end

      for end_time <- [nil, "18:30", "18:29", "invalid"] do
        attrs = if end_time, do: %{"end_time" => end_time}, else: %{}

        assert {:error, _} =
                 BeginnersWorkshops.execute(
                   {:staff, coordinator},
                   {:backfill_end_time, id, attrs},
                   clock: clock()
                 )
      end

      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, id, %{"end_time" => "20:30"}},
                 clock: clock()
               )

      assert {:error, :end_time_already_set} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, id, %{"end_time" => "21:00"}},
                 clock: clock()
               )

      after_backfill = Repo.get!(BeginnersWorkshop, id)

      assert Map.take(after_backfill, [:payment_cutoff, :contact_from, :reschedule_count]) ==
               Map.take(before, [:payment_cutoff, :contact_from, :reschedule_count])

      assert Repo.aggregate(IntakeEmailLog, :count) == emails_before
      assert Repo.aggregate(Notification, :count) == notifications_before
    end

    test "refuses cancelled, finalised and past legacy rows" do
      coordinator = staff_fixture()

      for status <- ["cancelled", "finalised"] do
        workshop = scheduled_fixture(coordinator)
        id = workshop.id
        force_status!(workshop.id, status)
        Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^id), set: [end_time: nil])

        assert {:error, reason} =
                 BeginnersWorkshops.execute(
                   {:staff, coordinator},
                   {:backfill_end_time, workshop.id, %{"end_time" => "20:30"}},
                   clock: clock()
                 )

        assert reason ==
                 if(status == "cancelled", do: :already_cancelled, else: :after_finalisation)
      end

      workshop = scheduled_fixture(coordinator)
      id = workshop.id

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^id),
        set: [date: ~D[2026-10-08], end_time: nil]
      )

      assert {:error, :not_due} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, workshop.id, %{"end_time" => "20:30"}},
                 clock: clock()
               )
    end

    test "excludes the exact start instant but includes a later workshop on the same Dublin day" do
      coordinator = staff_fixture()

      workshop =
        scheduled_fixture(coordinator, %{
          "date" => "2026-10-09",
          "start_time" => "13:00",
          "end_time" => "15:00",
          "contact_from" => "2026-10-06"
        })

      id = workshop.id

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^id),
        set: [start_time: ~T[12:00:00], end_time: nil]
      )

      assert BeginnersWorkshops.end_time_report(clock: clock()) == []

      assert {:error, :not_due} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, workshop.id, %{"end_time" => "14:00"}},
                 clock: clock()
               )

      later =
        scheduled_fixture(coordinator, %{
          "date" => "2026-10-09",
          "start_time" => "13:00",
          "end_time" => "15:00",
          "contact_from" => "2026-10-06"
        })

      later_id = later.id

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^later_id),
        set: [end_time: nil]
      )

      assert [%{id: ^later_id, issue: :missing}] =
               BeginnersWorkshops.end_time_report(clock: clock())

      assert {:ok, %{end_time: ~T[15:00:00]}} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:backfill_end_time, later.id, %{"end_time" => "15:00"}},
                 clock: clock()
               )
    end
  end
end
