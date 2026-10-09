defmodule Dhc.BeginnersWorkshops.CommandsTest do
  @moduledoc """
  ALE-378: the transition table, actor authorization, constraint
  declarations and the workshop commands of the one Beginners' Workshop
  boundary, exercised through `Dhc.BeginnersWorkshops.execute/3` with a fixed
  clock.
  """

  use Dhc.DataCase, async: true

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Commands}
  alias Dhc.Repo

  defp schedule(staff, list, opts \\ []),
    do:
      BeginnersWorkshops.execute(
        {:staff, staff},
        {:schedule_workshop, list},
        Keyword.put_new(opts, :clock, clock())
      )

  defp update_settings(staff, id, attrs, opts \\ []),
    do:
      BeginnersWorkshops.execute(
        {:staff, staff},
        {:update_workshop, id, attrs},
        Keyword.put_new(opts, :clock, clock())
      )

  defp count, do: Repo.aggregate(BeginnersWorkshop, :count)

  describe "the transition table" do
    test "declares exactly scheduled → finalised | cancelled for the workshop" do
      statuses = BeginnersWorkshop.statuses()

      legal =
        for from <- statuses,
            to <- statuses,
            Commands.transition_allowed?(:workshop, from, to),
            do: {from, to}

      assert Enum.sort(legal) == [{"scheduled", "cancelled"}, {"scheduled", "finalised"}]
      assert Commands.transitions() == %{workshop: %{"scheduled" => ~w(finalised cancelled)}}
    end

    test "the lock order is Beginners' Workshop → Waitlist entry → Intake → Carried Fee → payment → refund" do
      assert Commands.lock_levels() ==
               [:workshop, :waitlist_entry, :intake, :carried_fee, :payment, :refund]
    end

    test "every constraint persist/1 translates exists in the database" do
      existing =
        Repo.query!(
          "SELECT conname FROM pg_constraint UNION SELECT indexname FROM pg_indexes",
          []
        ).rows
        |> List.flatten()
        |> MapSet.new()

      for name <- Commands.declared_constraints(), do: assert(name in existing, name)
    end
  end

  describe "authorization before any read" do
    test "the beginners coordinator and every officer may schedule" do
      for role <- ~w(beginners_coordinator president admin committee_coordinator) do
        assert {:ok, [_view]} = schedule(staff_fixture(role), [workshop_attrs()])
      end
    end

    test "workshop coordinators, the treasurer, coaches and members are refused" do
      for role <- ~w(workshop_coordinator treasurer coach member) do
        assert {:error, :forbidden} = schedule(staff_fixture(role), [workshop_attrs()])
      end

      assert count() == 0
    end

    test "a refused actor learns nothing about the workshop, not even whether it exists" do
      member = staff_fixture("member")

      assert {:error, :forbidden} =
               update_settings(member, Ecto.UUID.generate(), %{"capacity" => 20})

      workshop = scheduled_fixture(staff_fixture())
      assert {:error, :forbidden} = update_settings(member, workshop.id, %{"capacity" => 20})
    end

    test "an inactive or unknown principal and non-staff actors are refused" do
      assert {:error, :forbidden} = schedule(Ecto.UUID.generate(), [workshop_attrs()])
      assert {:error, :forbidden} = schedule("not-a-uuid", [workshop_attrs()])

      for actor <- [:system, :stripe, {:intake_link, "token"}] do
        assert {:error, :forbidden} =
                 BeginnersWorkshops.execute(actor, {:schedule_workshop, [workshop_attrs()]})
      end
    end

    test "an unknown command is refused" do
      assert {:error, :unknown_command} =
               BeginnersWorkshops.execute({:staff, staff_fixture()}, {:launch_rocket, 1})
    end
  end

  describe "schedule_workshop" do
    setup do: %{staff: staff_fixture()}

    test "applies the defaults: cutoff 3 days before at the start time, contact from today, 7-day window",
         %{staff: staff} do
      assert {:ok, [view]} = schedule(staff, [workshop_attrs()])

      assert %{
               status: "scheduled",
               venue: "St. Andrew's Hall",
               date: ~D[2026-11-14],
               start_time: ~T[18:30:00],
               capacity: 16,
               fee_cents: 4000,
               payment_cutoff_date: ~D[2026-11-11],
               payment_cutoff_time: ~T[18:30:00],
               # 18:30 Dublin in November is 18:30 UTC.
               payment_cutoff: ~U[2026-11-11 18:30:00.000000Z],
               contact_from: ~D[2026-10-09],
               payment_window_days: 7,
               stage: :next_batch_due,
               seats: %{capacity: 16, paid: 0, holds: 0, free: 16},
               alerts: [:unstaffed]
             } = view

      assert %BeginnersWorkshop{scheduled_by_principal_id: ^staff} =
               Repo.get!(BeginnersWorkshop, view.id)
    end

    test "the default contact-from date is the Dublin day the clock reads", %{staff: staff} do
      # 23:30 UTC on 9 October is already 10 October in Dublin (IST).
      assert {:ok, [view]} =
               schedule(staff, [workshop_attrs()], clock: Clock.fixed(~U[2026-10-09 23:30:00Z]))

      assert view.contact_from == ~D[2026-10-10]
    end

    test "takes an explicit cutoff, contact-from date and window length", %{staff: staff} do
      assert {:ok, [view]} =
               schedule(staff, [
                 workshop_attrs(%{
                   "payment_cutoff_date" => "2026-11-12",
                   "payment_cutoff_time" => "12:00",
                   "contact_from" => "2026-10-20",
                   "payment_window_days" => 3
                 })
               ])

      assert view.payment_cutoff == ~U[2026-11-12 12:00:00.000000Z]
      assert view.contact_from == ~D[2026-10-20]
      assert view.payment_window_days == 3
      assert view.stage == :before_contact_from
    end

    test "a cutoff given only as a time keeps the default date", %{staff: staff} do
      assert {:ok, [view]} =
               schedule(staff, [workshop_attrs(%{"payment_cutoff_time" => "09:00"})])

      assert view.payment_cutoff_date == ~D[2026-11-11]
      assert view.payment_cutoff_time == ~T[09:00:00]
    end

    test "schedules several workshops at once, in request order", %{staff: staff} do
      assert {:ok, [first, second, third]} =
               schedule(staff, [
                 workshop_attrs(%{"date" => "2026-12-05"}),
                 workshop_attrs(%{"date" => "2026-11-14"}),
                 workshop_attrs(%{"date" => "2027-01-16", "venue" => "Hall B"})
               ])

      assert [first.date, second.date, third.date] ==
               [~D[2026-12-05], ~D[2026-11-14], ~D[2027-01-16]]

      assert count() == 3
    end

    test "is all or nothing and names the workshop that failed", %{staff: staff} do
      assert {:error, {:workshop, 1, :invalid_payment_cutoff}} =
               schedule(staff, [
                 workshop_attrs(),
                 workshop_attrs(%{"payment_cutoff_date" => "2026-11-15"})
               ])

      assert count() == 0
    end

    test "refuses a cutoff at or after the start", %{staff: staff} do
      for cutoff <- [
            %{"payment_cutoff_date" => "2026-11-14"},
            %{"payment_cutoff_date" => "2026-11-20"}
          ] do
        assert {:error, {:workshop, 0, :invalid_payment_cutoff}} =
                 schedule(staff, [workshop_attrs(Map.put(cutoff, "payment_cutoff_time", "18:30"))])
      end

      assert {:ok, [_]} =
               schedule(staff, [
                 workshop_attrs(%{
                   "payment_cutoff_date" => "2026-11-14",
                   "payment_cutoff_time" => "18:29"
                 })
               ])
    end

    test "refuses a contact-from date after the cutoff date", %{staff: staff} do
      assert {:error, {:workshop, 0, :invalid_contact_from}} =
               schedule(staff, [workshop_attrs(%{"contact_from" => "2026-11-12"})])

      assert {:ok, [view]} = schedule(staff, [workshop_attrs(%{"contact_from" => "2026-11-11"})])
      assert view.contact_from == ~D[2026-11-11]
    end

    test "refuses a workshop that has already started", %{staff: staff} do
      assert {:error, {:workshop, 0, :start_in_past}} =
               schedule(staff, [
                 workshop_attrs(%{"date" => "2026-10-09", "start_time" => "11:59"})
               ])

      assert {:ok, [_]} =
               schedule(staff, [
                 workshop_attrs(%{
                   "date" => "2026-10-09",
                   "start_time" => "12:01",
                   "payment_cutoff_date" => "2026-10-09",
                   "payment_cutoff_time" => "12:00"
                 })
               ])
    end

    test "validates the shape: venue up to 80 characters, positive capacity and fee, a window of at least a day",
         %{staff: staff} do
      for {attrs, field} <- [
            {workshop_attrs(%{"venue" => String.duplicate("v", 81)}), :venue},
            {workshop_attrs(%{"venue" => "   "}), :venue},
            {workshop_attrs(%{"capacity" => 0}), :capacity},
            {workshop_attrs(%{"fee_cents" => 0}), :fee_cents},
            {workshop_attrs(%{"fee_cents" => 100_000}), :fee_cents},
            {workshop_attrs(%{"payment_window_days" => 0}), :payment_window_days},
            {workshop_attrs(%{"date" => "not a date"}), :date},
            {Map.delete(workshop_attrs(), "start_time"), :start_time}
          ] do
        assert {:error, {:workshop, 0, %Ecto.Changeset{} = changeset}} = schedule(staff, [attrs])
        assert Keyword.has_key?(changeset.errors, field), inspect({field, changeset.errors})
      end

      assert {:ok, [view]} =
               schedule(staff, [workshop_attrs(%{"venue" => String.duplicate("v", 80)})])

      assert String.length(view.venue) == 80
      assert count() == 1
    end

    test "refuses an empty list and more than 20 at once", %{staff: staff} do
      assert {:error, :no_workshops} = schedule(staff, [])

      assert {:error, :too_many_workshops} =
               schedule(staff, List.duplicate(workshop_attrs(), 21))

      assert count() == 0
    end
  end

  describe "update_workshop" do
    setup do
      staff = staff_fixture()
      %{staff: staff, workshop: scheduled_fixture(staff)}
    end

    test "raises capacity and changes the fee and window length", %{staff: staff, workshop: w} do
      assert {:ok, view} =
               update_settings(staff, w.id, %{
                 "capacity" => 24,
                 "fee_cents" => 4500,
                 "payment_window_days" => 5
               })

      assert %{capacity: 24, fee_cents: 4500, payment_window_days: 5} = view
      assert view.seats.capacity == 24
      # Unchanged settings keep their values.
      assert view.payment_cutoff == w.payment_cutoff
      assert view.contact_from == w.contact_from
    end

    test "edits the Payment Cutoff, keeping the other half of it", %{staff: staff, workshop: w} do
      assert {:ok, view} = update_settings(staff, w.id, %{"payment_cutoff_date" => "2026-11-13"})
      assert view.payment_cutoff == ~U[2026-11-13 18:30:00.000000Z]

      assert {:ok, view} = update_settings(staff, w.id, %{"payment_cutoff_time" => "20:00"})
      assert view.payment_cutoff == ~U[2026-11-13 20:00:00.000000Z]
    end

    test "refuses a cutoff that is not before the start", %{staff: staff, workshop: w} do
      assert {:error, :invalid_payment_cutoff} =
               update_settings(staff, w.id, %{"payment_cutoff_date" => "2026-11-14"})

      assert Repo.get!(BeginnersWorkshop, w.id).payment_cutoff == w.payment_cutoff
    end

    test "edits the contact-from date before Batch 1, on or before the cutoff date",
         %{staff: staff, workshop: w} do
      assert w.contact_from_editable

      assert {:ok, %{contact_from: ~D[2026-11-01]}} =
               update_settings(staff, w.id, %{"contact_from" => "2026-11-01"})

      assert {:error, :invalid_contact_from} =
               update_settings(staff, w.id, %{"contact_from" => "2026-11-12"})

      # Moving the cutoff before the contact-from date is refused the same way.
      assert {:error, :invalid_contact_from} =
               update_settings(staff, w.id, %{"payment_cutoff_date" => "2026-10-31"})
    end

    test "validates the shape of the new values", %{staff: staff, workshop: w} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               update_settings(staff, w.id, %{"capacity" => 0})

      assert Keyword.has_key?(changeset.errors, :capacity)

      assert {:error, %Ecto.Changeset{}} =
               update_settings(staff, w.id, %{"payment_window_days" => 0})

      assert {:error, %Ecto.Changeset{}} =
               update_settings(staff, w.id, %{"contact_from" => "soon"})
    end

    test "ignores attributes it does not own", %{staff: staff, workshop: w} do
      assert {:ok, view} =
               update_settings(staff, w.id, %{"venue" => "Elsewhere", "status" => "cancelled"})

      assert %{venue: "St. Andrew's Hall", status: "scheduled"} = view
    end

    test "is refused once the workshop is finalised or cancelled", %{staff: staff, workshop: w} do
      force_status!(w.id, "finalised")
      assert {:error, :after_finalisation} = update_settings(staff, w.id, %{"capacity" => 30})

      other = scheduled_fixture(staff)
      force_status!(other.id, "cancelled")
      assert {:error, :already_cancelled} = update_settings(staff, other.id, %{"capacity" => 30})
    end

    test "an unknown workshop is not found", %{staff: staff} do
      assert {:error, :not_found} =
               update_settings(staff, Ecto.UUID.generate(), %{"capacity" => 30})

      assert {:error, :not_found} = update_settings(staff, "nope", %{"capacity" => 30})
    end
  end
end
