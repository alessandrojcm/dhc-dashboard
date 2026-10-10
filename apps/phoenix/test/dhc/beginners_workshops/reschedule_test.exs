defmodule Dhc.BeginnersWorkshops.RescheduleTest do
  @moduledoc """
  ALE-394: `reschedule_workshop` through `Dhc.BeginnersWorkshops.execute/3`
  with fixed clocks.

  The workshop under test (`contacted_fixture/3`) is Saturday 14 November
  2026 at 18:30 Dublin, Payment Cutoff Wednesday 11 November 18:30 (GMT, so
  18:30 UTC), Batch 1 sent at 10:00 on 20 October with a window to 27
  October 23:59. Dublin leaves summer time on 25 October.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe

  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakePayment
  }

  alias Dhc.Email.Worker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  # Batch 1's window is open (it ends on 27 October).
  @now ~U[2026-10-22 12:00:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp reschedule(actor, workshop, attrs, at \\ @now),
    do:
      BeginnersWorkshops.execute(
        {:staff, actor},
        {:reschedule_workshop, workshop.id, attrs},
        clock: Clock.fixed(at)
      )

  defp rescheduled_logs(workshop) do
    Repo.all(
      from(l in IntakeEmailLog,
        join: i in Intake,
        on: i.id == l.intake_id,
        where: i.workshop_id == ^workshop.id and l.email_type == "rescheduled",
        select: {l.intake_id, l.occasion}
      )
    )
  end

  defp rescheduled_jobs do
    Enum.filter(all_enqueued(worker: Worker), &(&1.args["subject"] =~ "has moved to"))
  end

  defp payment!(intake),
    do:
      Repo.one!(
        from(p in IntakePayment,
          where: p.intake_id == ^intake.id,
          order_by: [desc: p.created_at],
          limit: 1
        )
      )

  defp paid!(token, intake) do
    Stripe.stub_create()

    assert {:ok, _} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Clock.fixed(@now)
             )

    assert {:ok, %{outcome: :paid}} =
             BeginnersWorkshops.execute(
               :stripe,
               {:complete_payment, Stripe.session(payment!(intake))},
               clock: Clock.fixed(@now)
             )
  end

  describe "moving a workshop with Batch 1 out" do
    test "a pending Batch never blocks it; the cutoff keeps its offset and everyone open is told",
         %{coordinator: coordinator} do
      {workshop, [{paid, paid_token}, {asked, _}, {closed, _}]} =
        contacted_fixture(coordinator, 3)

      paid!(paid_token, paid)
      force_intake_state!(closed.id, "lapsed")
      {:ok, before} = BeginnersWorkshops.workshop_console(workshop.id, clock: Clock.fixed(@now))

      assert {:ok, view} =
               reschedule(coordinator, workshop, %{
                 "date" => "2026-11-21",
                 "start_time" => "19:00",
                 "venue" => "  The Hub  "
               })

      # 3 days before at the new start time (Dublin GMT = UTC in November).
      assert view.date == ~D[2026-11-21]
      assert view.start_time == ~T[19:00:00]
      assert view.venue == "The Hub"
      assert view.payment_cutoff == ~U[2026-11-18 19:00:00.000000Z]
      # Batch 1 has gone out, so the contact-from date stays.
      assert view.contact_from == ~D[2026-10-20]
      assert view.seats == before.workshop.seats

      # Every open Intake, and only those, gets "Workshop rescheduled" once.
      assert Enum.sort(rescheduled_logs(workshop)) ==
               Enum.sort([{paid.id, "rescheduled:1"}, {asked.id, "rescheduled:1"}])

      assert [_, _] = jobs = rescheduled_jobs()

      assert Enum.all?(jobs, fn %{args: args} ->
               args["transactional_id"] == "beginnersWorkshopAction" and
                 args["data_variables"]["BUTTON_LABEL"] == "View my place" and
                 args["data_variables"]["MESSAGE_HTML"] =~ "The Hub"
             end)

      # Seats and chances to pay are unchanged.
      assert %Intake{state: "paid"} = Repo.reload!(paid)
      assert %Intake{state: "contacted"} = Repo.reload!(asked)
      assert %Intake{state: "lapsed"} = Repo.reload!(closed)

      # The window ends before the new cutoff, so it keeps its end.
      assert [%Batch{window_ends_at: ~U[2026-10-27 23:59:59.999999Z]}] =
               Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))

      # A second reschedule is a new occasion: people are told again.
      assert {:ok, _} = reschedule(coordinator, workshop, %{"venue" => "St. Andrew's Hall"})

      assert {paid.id, "rescheduled:2"} in rescheduled_logs(workshop)
      assert [_, _, _, _] = rescheduled_jobs()
    end

    test "an open Batch window is clamped to an earlier new cutoff", %{coordinator: coordinator} do
      {workshop, _intakes} = contacted_fixture(coordinator, 2)

      # Cutoff 3 days before: 25 October 18:30 Dublin (GMT from 01:00 that day).
      assert {:ok, view} = reschedule(coordinator, workshop, %{"date" => "2026-10-28"})
      assert view.payment_cutoff == ~U[2026-10-25 18:30:00.000000Z]

      assert [%Batch{window_ends_at: ~U[2026-10-25 18:30:00.000000Z]}] =
               Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))
    end

    test "a supplied cutoff replaces the kept one, and a closed window is left alone", %{
      coordinator: coordinator
    } do
      {workshop, _intakes} = contacted_fixture(coordinator, 1)
      # After Batch 1's window closed.
      at = ~U[2026-10-29 12:00:00.000000Z]

      assert {:ok, view} =
               reschedule(
                 coordinator,
                 workshop,
                 %{
                   "date" => "2026-11-07",
                   "payment_cutoff_date" => "2026-10-27",
                   "payment_cutoff_time" => "12:00"
                 },
                 at
               )

      assert view.payment_cutoff == ~U[2026-10-27 12:00:00.000000Z]

      assert [%Batch{window_ends_at: ~U[2026-10-27 23:59:59.999999Z]}] =
               Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))
    end

    test "the contact-from date can no longer change", %{coordinator: coordinator} do
      {workshop, _intakes} = contacted_fixture(coordinator, 1)

      assert {:error, :contact_from_locked} =
               reschedule(coordinator, workshop, %{
                 "date" => "2026-11-21",
                 "contact_from" => "2026-11-01"
               })

      # The same date is not a change.
      assert {:ok, _} =
               reschedule(coordinator, workshop, %{
                 "date" => "2026-11-21",
                 "contact_from" => "2026-10-20"
               })
    end
  end

  describe "moving a workshop before Batch 1" do
    test "the contact-from date keeps its offset and the next Batch follows it", %{
      coordinator: coordinator
    } do
      workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20"})

      assert {:ok, view} = reschedule(coordinator, workshop, %{"date" => "2026-11-21"}, now())

      assert view.contact_from == ~D[2026-10-27]
      assert view.payment_cutoff == ~U[2026-11-18 18:30:00.000000Z]
      assert view.stage == :before_contact_from

      {:ok, console} = BeginnersWorkshops.workshop_console(workshop.id, clock: clock())
      # 10:00 Dublin (GMT) on 27 October.
      assert console.next_batch.goes_out_at == ~U[2026-10-27 10:00:00Z]

      # Nobody is open yet, so nobody is emailed.
      assert rescheduled_jobs() == []
    end

    test "a kept date after the new cutoff date comes forward to today", %{
      coordinator: coordinator
    } do
      workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-11-10"})
      waiting_people_fixture(1)

      # Kept: 4 days before the new date = 8 November, after the 1 November cutoff.
      assert {:ok, view} =
               reschedule(
                 coordinator,
                 workshop,
                 %{"date" => "2026-11-12", "payment_cutoff_date" => "2026-11-01"},
                 now()
               )

      assert view.contact_from == ~D[2026-10-09]

      # 12:00 Dublin today, past 10:00: Batch 1 goes out at the next sweep.
      assert {:ok, %{outcome: :sent}} =
               BeginnersWorkshops.execute(:system, {:send_due_batch, workshop.id}, clock: clock())
    end

    test "a supplied contact-from date is judged by update_workshop's rule", %{
      coordinator: coordinator
    } do
      workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20"})

      assert {:error, :invalid_contact_from} =
               reschedule(
                 coordinator,
                 workshop,
                 %{"date" => "2026-11-21", "contact_from" => "2026-11-19"},
                 now()
               )

      assert {:ok, %{contact_from: ~D[2026-11-02]}} =
               reschedule(
                 coordinator,
                 workshop,
                 %{"date" => "2026-11-21", "contact_from" => "2026-11-02"},
                 now()
               )
    end
  end

  describe "Pre-workshop info" do
    test "is sent again at the new cutoff to anyone who already had it", %{
      coordinator: coordinator
    } do
      {workshop, [{paid, paid_token}, {_unpaid, _}]} = contacted_fixture(coordinator, 2)
      paid!(paid_token, paid)

      sweep = fn at -> BeginnersWorkshops.run_due_passes(clock: Clock.fixed(at)) end

      assert %{cutoff_pre_workshop: 1, cutoff_lapsed: 1} = sweep.(@cutoff)

      # After the old cutoff: moved a week later, cutoff 18 November.
      moved_at = ~U[2026-11-12 09:00:00.000000Z]
      assert {:ok, view} = reschedule(coordinator, workshop, %{"date" => "2026-11-21"}, moved_at)
      assert view.payment_cutoff == ~U[2026-11-18 18:30:00.000000Z]

      # Not owed again until the new cutoff.
      assert %{cutoff_pre_workshop: 0} = sweep.(moved_at)

      assert %{cutoff_pre_workshop: 1} = sweep.(~U[2026-11-18 18:30:00.000000Z])

      occasions =
        Repo.all(
          from(l in IntakeEmailLog,
            where: l.intake_id == ^paid.id and l.email_type == "pre_workshop",
            order_by: l.queued_at,
            select: l.occasion
          )
        )

      assert occasions == ["pre_workshop", "pre_workshop:1"]

      # Exactly once per schedule.
      assert %{cutoff_pre_workshop: 0} = sweep.(~U[2026-11-18 19:00:00.000000Z])
    end
  end

  describe "Staff" do
    test "stay assigned and get a keyed Notification for each reschedule", %{
      coordinator: coordinator
    } do
      coach = staff_fixture("coach")
      assistant = staff_fixture("member")
      workshop = scheduled_fixture(coordinator)
      set_staff!(workshop.id, coach, [assistant, coordinator], actor: coordinator)

      notifications = fn principal_id ->
        Repo.all(
          from(n in Notification,
            where:
              n.principal_id == ^principal_id and
                like(n.notification_key, "beginners-workshop:%:rescheduled:%"),
            order_by: n.notification_key,
            select: {n.notification_key, n.body}
          )
        )
      end

      assert {:ok, view} = reschedule(coordinator, workshop, %{"date" => "2026-11-21"}, now())
      assert view.staff.coach.principal_id == coach
      assert [_, _] = view.staff.assistants

      assert {:ok, _} = reschedule(coordinator, workshop, %{"start_time" => "19:00"}, now())

      for principal_id <- [coach, assistant] do
        assert [{key_1, body_1}, {key_2, body_2}] = notifications.(principal_id)
        assert key_1 == "beginners-workshop:#{workshop.id}:rescheduled:1"
        assert key_2 == "beginners-workshop:#{workshop.id}:rescheduled:2"
        assert body_1 =~ "Sat 21 Nov 2026 at 18:30"
        assert body_2 =~ "Sat 21 Nov 2026 at 19:00"
      end

      # The person making the change already knows.
      assert notifications.(coordinator) == []
    end
  end

  describe "refusals" do
    test "only after finalisation or cancellation", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      force_status!(workshop.id, "cancelled")

      assert {:error, :already_cancelled} =
               reschedule(coordinator, workshop, %{"date" => "2026-11-21"}, now())

      force_status!(workshop.id, "finalised")

      assert {:error, :after_finalisation} =
               reschedule(coordinator, workshop, %{"date" => "2026-11-21"}, now())
    end

    test "the input must move the workshop to a valid start", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      assert {:error, %Ecto.Changeset{errors: [date: _]}} =
               reschedule(coordinator, workshop, %{"venue" => workshop.venue}, now())

      assert {:error, :start_in_past} =
               reschedule(coordinator, workshop, %{"date" => "2026-10-01"}, now())

      assert {:error, :invalid_payment_cutoff} =
               reschedule(
                 coordinator,
                 workshop,
                 %{"date" => "2026-11-21", "payment_cutoff_date" => "2026-11-22"},
                 now()
               )

      assert {:error, %Ecto.Changeset{errors: [venue: _]}} =
               reschedule(coordinator, workshop, %{"venue" => String.duplicate("x", 81)}, now())

      assert %BeginnersWorkshop{date: ~D[2026-11-14], reschedule_count: 0} =
               Repo.get!(BeginnersWorkshop, workshop.id)
    end

    test "needs beginners.workshops.manage", %{coordinator: coordinator} do
      workshop = scheduled_fixture(coordinator)

      assert {:error, :forbidden} =
               reschedule(staff_fixture("coach"), workshop, %{"date" => "2026-11-21"}, now())

      assert {:error, :not_found} =
               reschedule(coordinator, %{id: Ecto.UUID.generate()}, %{"date" => "2026-11-21"})
    end
  end

  test "a Waitlist entry is never touched", %{coordinator: coordinator} do
    {workshop, [{intake, _}]} = contacted_fixture(coordinator, 1)
    before = Repo.get!(WaitlistEntry, intake.waitlist_id)

    assert {:ok, _} = reschedule(coordinator, workshop, %{"date" => "2026-11-21"})
    assert Repo.get!(WaitlistEntry, intake.waitlist_id) == before
  end
end
