defmodule Dhc.BeginnersWorkshops.AttendanceFinalisationTest do
  @moduledoc """
  ALE-391: Attendance Finalisation and the Follow-up, through
  `Dhc.BeginnersWorkshops.execute/3` and the sweep with fixed clocks.

  `finish_workshop` (assigned Staff, from the door) and the automatic
  `finalise_attendance` turn checked-in `paid` Intakes into `attended`
  (standing `attended`) and the rest into `no_show` (standing `removed`, no
  email), close any Intake still `contacted` by the Payment Cutoff rule,
  close check-in and freeze the Staff list. `send_follow_ups` queues the
  Follow-up once per attended Intake at 10:00 Dublin the morning after.

  The workshop under test is Saturday 24 October 2026 at 11:00 Dublin
  (IST, 10:00Z). Summer time ends at 02:00 on Sunday 25 October, so the end
  of the workshop's Dublin day is 23:00Z (midnight IST) and the Follow-up's
  10:00 the next morning is 10:00Z (GMT).
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Intake,
    IntakeEmailLog,
    IntakePayment,
    StaffAssignment
  }

  alias Dhc.Email.Worker
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @during ~U[2026-10-24 10:30:00.000000Z]
  # The last instant of 24 October in Dublin (IST), and midnight after it.
  @day_ends_before ~U[2026-10-24 22:59:59.999999Z]
  @day_ended ~U[2026-10-24 23:00:00.000000Z]
  # 10:00 Dublin on Sunday 25 October, after the clocks went back (GMT).
  @follow_up ~U[2026-10-25 10:00:00.000000Z]

  setup do
    coordinator = staff_fixture()
    coach = staff_fixture("coach", %{first_name: "Aoife", last_name: "Coach"})
    assistant = staff_fixture("member", %{first_name: "Brian", last_name: "Assist"})
    outsider = staff_fixture("member")

    workshop =
      scheduled_fixture(coordinator, %{"date" => "2026-10-24", "start_time" => "11:00"})

    set_staff!(workshop.id, coach, [assistant])

    in_person = paid_person_fixture!(workshop.id, first_name: "Niamh")
    absent = paid_person_fixture!(workshop.id, first_name: "Oisín")

    %{
      coordinator: coordinator,
      coach: coach,
      assistant: assistant,
      outsider: outsider,
      workshop: workshop,
      in_person: in_person,
      absent: absent
    }
  end

  defp finish(actor, ctx, at \\ @during),
    do:
      BeginnersWorkshops.execute({:staff, actor}, {:finish_workshop, ctx.workshop.id},
        clock: clock(at)
      )

  defp finalise(ctx, at),
    do:
      BeginnersWorkshops.execute(:system, {:finalise_attendance, ctx.workshop.id},
        clock: clock(at)
      )

  defp follow_ups(ctx, at),
    do: BeginnersWorkshops.execute(:system, {:send_follow_ups, ctx.workshop.id}, clock: clock(at))

  defp check_in!(ctx, intake, at \\ @during) do
    {:ok, _} =
      BeginnersWorkshops.execute(
        {:staff, ctx.assistant},
        {:check_in, ctx.workshop.id, intake.id},
        clock: clock(at)
      )
  end

  defp entry(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)

  defp follow_up_jobs,
    do:
      Enum.filter(
        all_enqueued(worker: Worker),
        &(&1.args["transactional_id"] == "beginnersWorkshopNotice")
      )

  defp follow_up_logs(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog, where: l.intake_id == ^intake.id and l.occasion == "follow_up")
      )

  describe "finish_workshop" do
    test "checked-in people attend, the rest are no-shows, with no email", ctx do
      check_in!(ctx, ctx.in_person)
      emails_before = length(all_enqueued(worker: Worker))

      assert {:ok, %{outcome: :finalised, attended: 1, no_show: 1, lapsed: 0, returned: 0}} =
               finish(ctx.assistant, ctx)

      assert %Intake{state: "attended", checked_in_at: %DateTime{}} = Repo.reload!(ctx.in_person)
      assert %Intake{state: "no_show"} = Repo.reload!(ctx.absent)
      assert %WaitlistEntry{status: "attended"} = entry(ctx.in_person)
      assert %WaitlistEntry{status: "removed", removed_at: %DateTime{}} = entry(ctx.absent)
      assert length(all_enqueued(worker: Worker)) == emails_before

      workshop = Repo.get!(BeginnersWorkshop, ctx.workshop.id)
      assert %{status: "finalised", finalised_at: @during} = workshop
      assert workshop.finalised_by_principal_id == ctx.assistant
    end

    test "closes check-in and refuses a second Finish", ctx do
      assert {:ok, %{outcome: :finalised}} = finish(ctx.coach, ctx)

      assert {:error, :check_in_closed} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coach},
                 {:check_in, ctx.workshop.id, ctx.absent.id},
                 clock: clock(@during)
               )

      assert {:error, :after_finalisation} = finish(ctx.coach, ctx)
      assert {:ok, %{outcome: :not_due}} = finalise(ctx, @day_ended)
    end

    test "freezes the Staff list, keeping names after a person leaves the club", ctx do
      assert {:ok, _} = finish(ctx.coach, ctx)

      assert Repo.all(from(s in StaffAssignment, where: s.workshop_id == ^ctx.workshop.id))
             |> Enum.map(& &1.frozen_name)
             |> Enum.sort() == ["Aoife Coach", "Brian Assist"]

      # The coach leaves the club and their profile is anonymised.
      from(p in UserProfile, where: p.principal_id == ^ctx.coach)
      |> Repo.update_all(set: [first_name: "Anonymised", last_name: ""])

      {:ok, view, _resource} =
        BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock(@during))

      assert view.staff.coach.name == "Aoife Coach"
      assert [%{name: "Brian Assist"}] = view.staff.assistants

      assert {:error, :after_finalisation} =
               BeginnersWorkshops.execute(
                 {:staff, ctx.coordinator},
                 {:set_staff, ctx.workshop.id, %{"coach_principal_id" => nil}},
                 clock: clock(@during)
               )
    end

    test "is refused before check-in opens", ctx do
      assert {:error, :check_in_not_open} = finish(ctx.coach, ctx, ~U[2026-10-24 08:59:59Z])
      assert {:ok, %{outcome: :finalised}} = finish(ctx.coach, ctx, ~U[2026-10-24 09:00:00Z])
    end

    test "is refused before any read for someone not on the Staff", ctx do
      assert {:error, :not_found} = finish(ctx.outsider, ctx)
      assert {:error, :not_found} = finish(ctx.outsider, %{workshop: %{id: Ecto.UUID.generate()}})
      assert %Intake{state: "paid"} = Repo.reload!(ctx.absent)
    end

    test "closes anyone still contacted by the cutoff rule, and waits for a live Seat Hold",
         ctx do
      lapsing = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      {contacted, _token} = intake_fixture!(ctx.workshop.id, lapsing)

      paying = waiting_person_fixture(~U[2025-02-02 12:00:00Z])
      {holding, _token} = intake_fixture!(ctx.workshop.id, paying)

      hold =
        %{
          workshop_id: ctx.workshop.id,
          intake_id: holding.id,
          amount_cents: 4000,
          expires_at: DateTime.add(@during, 600, :second)
        }
        |> IntakePayment.hold_changeset()
        |> Repo.insert!()

      assert {:error, :payment_in_progress} = finish(ctx.coach, ctx)
      assert {:ok, %{outcome: :awaiting_hold}} = finalise(ctx, @day_ended)

      assert %BeginnersWorkshop{status: "scheduled"} =
               Repo.get!(BeginnersWorkshop, ctx.workshop.id)

      hold |> Ecto.Changeset.change(status: "released") |> Repo.update!()

      assert {:ok, %{outcome: :finalised, lapsed: 2, no_show: 2}} = finish(ctx.coach, ctx)
      assert %Intake{state: "lapsed"} = Repo.reload!(contacted)
      assert %WaitlistEntry{status: "removed"} = entry(contacted)
    end
  end

  describe "finalise_attendance" do
    test "runs at the end of the Dublin day across the clocks going back", ctx do
      check_in!(ctx, ctx.in_person)

      assert {:ok, %{outcome: :not_due}} = finalise(ctx, @during)
      assert {:ok, %{outcome: :not_due}} = finalise(ctx, @day_ends_before)

      assert {:ok, %{outcome: :finalised, attended: 1, no_show: 1}} = finalise(ctx, @day_ended)

      workshop = Repo.get!(BeginnersWorkshop, ctx.workshop.id)
      assert %{status: "finalised", finalised_by_principal_id: nil} = workshop

      assert {:ok, %{outcome: :not_due}} = finalise(ctx, DateTime.add(@day_ended, 300))
    end

    test "the sweep finalises once, then sends the Follow-up once", ctx do
      check_in!(ctx, ctx.in_person)

      assert %{finalised: 0} = BeginnersWorkshops.run_due_passes(clock: clock(@day_ends_before))

      assert %{finalised: 1, follow_ups: 0, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: clock(@day_ended))

      assert %{finalised: 0, follow_ups: 0} =
               BeginnersWorkshops.run_due_passes(clock: clock(DateTime.add(@day_ended, 300)))

      assert %{follow_ups: 0} =
               BeginnersWorkshops.run_due_passes(clock: clock(DateTime.add(@follow_up, -1)))

      assert %{follow_ups: 1, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: clock(@follow_up))

      assert %{follow_ups: 0, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: clock(DateTime.add(@follow_up, 300)))

      assert [_one] = follow_up_logs(ctx.in_person)
      assert follow_up_logs(ctx.absent) == []
    end
  end

  describe "send_follow_ups" do
    test "queues the Follow-up at 10:00 Dublin the morning after, to attended people only", ctx do
      check_in!(ctx, ctx.in_person)
      assert {:ok, _} = finish(ctx.coach, ctx)

      assert {:ok, %{outcome: :not_due}} = follow_ups(ctx, DateTime.add(@follow_up, -1))
      assert follow_up_jobs() == []

      assert {:ok, %{outcome: :sent, follow_ups: 1}} = follow_ups(ctx, @follow_up)

      assert [%IntakeEmailLog{email_type: "follow_up", queued_at: @follow_up}] =
               follow_up_logs(ctx.in_person)

      in_person = entry(ctx.in_person)
      assert [%{args: %{"email" => email}}] = follow_up_jobs()
      assert email == in_person.email

      assert {:ok, %{outcome: :sent, follow_ups: 0}} = follow_ups(ctx, @follow_up)
      assert [_one] = follow_up_jobs()
    end

    test "is not due before finalisation", ctx do
      assert {:ok, %{outcome: :not_due}} = follow_ups(ctx, @follow_up)
    end
  end

  describe "the read models" do
    test "the door and console show the finalised summary, meter and roster", ctx do
      check_in!(ctx, ctx.in_person)
      assert {:ok, _} = finish(ctx.coach, ctx)

      {:ok, door, _resource} =
        BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock(@during))

      assert door.finalisation == %{at: @during, by: "Aoife Coach", attended: 1, no_show: 1}
      assert door.check_in.window == :closed
      assert door.stage == :finalised
      assert Enum.map(door.people, & &1.state) |> Enum.sort() == ~w(attended no_show)

      {:ok, console} = BeginnersWorkshops.workshop_console(ctx.workshop.id, clock: clock(@during))
      assert %{attended: 1, no_show: 1} = console.workshop.seats
      assert [%{id: attended_id}] = console.roster.attended
      assert attended_id == ctx.in_person.id
      assert [%{state: "no_show"}] = console.roster.no_show
      assert console.roster.seated == [] and console.roster.out == []

      assert %{at: @during, by: "Aoife Coach", follow_up_at: follow_up_at} = console.finalisation
      assert DateTime.compare(follow_up_at, @follow_up) == :eq
    end

    test "an automatic finalisation names nobody", ctx do
      assert {:ok, _} = finalise(ctx, @day_ended)

      {:ok, door, _resource} =
        BeginnersWorkshops.door_view(ctx.workshop.id, clock: clock(@day_ended))

      assert %{by: nil, attended: 0, no_show: 2} = door.finalisation

      assert [%{stage: :finalised}] =
               BeginnersWorkshops.list_workshops(clock: clock(@day_ended)).past
    end
  end
end
