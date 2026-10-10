defmodule Dhc.BeginnersWorkshops.CancelWorkshopTest do
  @moduledoc """
  ALE-395: `cancel_workshop` through `Dhc.BeginnersWorkshops.execute/3`
  with fixed clocks and Stripe stubbed at the HTTP seam — paid people
  deferred (a Stripe payment becomes a `held` Carried Fee, a Carried Fee
  that paid goes back to `held`) with their check-in discarded, contacted
  people returned with their priority, live holds released, the notices,
  the history rows and the Staff Notification; a late completion on a
  released hold; that no pass, hold, confirm, check-in or scheduled email
  happens afterwards; moving people on by fast-tracking the holders; the
  console's preview and record, the list's stage; and every refusal.

  The workshop under test is `contacted_fixture/2`'s (Saturday 14 November
  2026 18:30, fee €40, cutoff 11 November 18:30 UTC, Batch 1 on 20
  October with a window to 27 October).
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakeLink,
    IntakePayment,
    IntakeRefund,
    WorkshopConsole
  }

  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  # Batch 1's window is open (it ends on 27 October).
  @now ~U[2026-10-22 12:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp cancel(c, workshop, attrs \\ %{}, at \\ @now),
    do: execute({:staff, c}, {:cancel_workshop, workshop.id, attrs}, at)

  defp hold!(token, intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)

    Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))
  end

  defp paid!(token, intake) do
    payment = hold!(token, intake)

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(payment)})

    Repo.reload!(payment)
  end

  defp entry(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)

  defp fees(intake),
    do: Repo.all(from(f in CarriedFee, where: f.waitlist_id == ^intake.waitlist_id))

  defp notices(intake) do
    Repo.all(
      from(l in IntakeEmailLog,
        where:
          l.intake_id == ^intake.id and
            l.email_type not in ~w(contact_pay contact_confirm place_confirmed_paid),
        select: {l.email_type, l.occasion}
      )
    )
  end

  # A workshop of four contacted people, then: #1 paid by Stripe and
  # checked in, #2 in Stripe Checkout (a live hold), #3 contacted, #4 paid
  # by a Carried Fee.
  defp mixed_fixture(c) do
    {workshop, [{one, t1}, {two, t2}, {three, t3}, {four, _t4}]} = contacted_fixture(c, 4)
    payment = paid!(t1, one)

    one
    |> Repo.reload!()
    |> Intake.check_in_changeset(c, @now)
    |> Repo.update!()

    hold = hold!(t2, two)
    four = force_carried_fee_paid!(four)

    %{
      workshop: workshop,
      paid: Repo.reload!(one),
      payment: payment,
      held: two,
      hold: hold,
      contacted: three,
      carried: four,
      tokens: %{one: t1, two: t2, three: t3}
    }
  end

  describe "cancel_workshop" do
    test "defers the paid, returns the contacted, releases holds and tells everyone",
         %{coordinator: c} do
      f = mixed_fixture(c)
      priorities = Map.new([f.paid, f.held, f.contacted, f.carried], &{&1.id, entry(&1)})

      assert {:ok, %{deferred: 2, returned: 2, released: 1, workshop: view}} =
               cancel(c, f.workshop, %{"reason" => "  Hall flooded  "})

      assert view.status == "cancelled"
      assert view.stage == :cancelled

      assert %BeginnersWorkshop{
               status: "cancelled",
               cancelled_at: @now,
               cancelled_by_principal_id: ^c,
               cancel_reason: "Hall flooded"
             } = Repo.get!(BeginnersWorkshop, f.workshop.id)

      # Paid → deferred, the check-in discarded.
      assert %Intake{state: "deferred", checked_in_at: nil, checked_in_by_principal_id: nil} =
               Repo.reload!(f.paid)

      assert %Intake{state: "deferred"} = Repo.reload!(f.carried)

      # Contacted → returned.
      assert %Intake{state: "returned"} = Repo.reload!(f.held)
      assert %Intake{state: "returned"} = Repo.reload!(f.contacted)

      # The Stripe payer's fee is a held Carried Fee pointing at the payment.
      payment_id = f.payment.id

      assert [
               %CarriedFee{
                 status: "held",
                 origin: "deferral",
                 payment_id: ^payment_id,
                 amount_cents: 4000
               }
             ] = fees(f.paid)

      # The Carried Fee that paid goes back to held.
      assert [%CarriedFee{status: "held", applied_intake_id: nil}] = fees(f.carried)

      # The live hold is releasing; Stripe still ends it.
      assert %IntakePayment{status: "releasing"} = Repo.reload!(f.hold)
      assert %IntakePayment{status: "paid"} = Repo.reload!(f.payment)

      # Everyone is waiting with their original priority.
      for intake <- [f.paid, f.held, f.contacted, f.carried] do
        before = Map.fetch!(priorities, intake.id)

        assert %WaitlistEntry{status: "waiting", initial_registration_date: date} =
                 entry(intake)

        assert date == before.initial_registration_date
      end

      # "Workshop cancelled – paid" replaces "Deferred".
      assert notices(f.paid) == [{"cancelled_paid", "cancelled"}]
      assert notices(f.carried) == [{"cancelled_paid", "cancelled"}]
      assert notices(f.held) == [{"cancelled_unpaid", "cancelled"}]
      assert notices(f.contacted) == [{"cancelled_unpaid", "cancelled"}]

      # One history row per Intake, carrying the reason.
      events =
        Repo.all(
          from(e in IntakeEvent,
            join: i in Intake,
            on: i.id == e.intake_id,
            where: i.workshop_id == ^f.workshop.id,
            select: {e.intake_id, e.command, e.actor_principal_id, e.note}
          )
        )

      assert Enum.sort(events) ==
               Enum.sort(
                 for intake <- [f.paid, f.held, f.contacted, f.carried],
                     do: {intake.id, "cancel_workshop", c, "Hall flooded"}
               )
    end

    test "an empty workshop cancels with nothing to do, and a blank reason is none",
         %{coordinator: c} do
      workshop = scheduled_fixture(c)

      assert {:ok, %{deferred: 0, returned: 0, released: 0}} =
               cancel(c, workshop, %{"reason" => "   "})

      assert %BeginnersWorkshop{status: "cancelled", cancel_reason: nil} =
               Repo.get!(BeginnersWorkshop, workshop.id)
    end

    test "a contacted Carried Fee holder keeps their held fee", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_holder_fixture(c)

      assert {:ok, %{returned: 1}} = cancel(c, workshop)
      assert %Intake{state: "returned"} = Repo.reload!(intake)
      assert [%CarriedFee{status: "held"}] = fees(intake)
    end

    test "a paid person whose Waitlist entry was deleted is closed without a fee",
         %{coordinator: c} do
      {workshop, [{intake, token}]} = contacted_fixture(c, 1)
      paid!(token, intake)
      # As a hard-deleted Waitlist entry leaves it (`on_delete: :nilify_all`).
      Repo.update_all(from(i in Intake, where: i.id == ^intake.id), set: [waitlist_id: nil])

      assert {:ok, %{deferred: 1}} = cancel(c, workshop)
      assert %Intake{state: "deferred", waitlist_id: nil} = Repo.reload!(intake)
      refute Repo.exists?(CarriedFee)
    end

    test "assigned Staff get a keyed Notification, the actor none", %{coordinator: c} do
      coach = staff_fixture("coach")
      assistant = staff_fixture("member")
      workshop = scheduled_fixture(c)
      set_staff!(workshop.id, coach, [assistant, c], actor: c)

      assert {:ok, _} = cancel(c, workshop)

      key = "beginners-workshop:#{workshop.id}:cancelled"

      notified =
        Repo.all(
          from(n in Notification,
            where: n.notification_key == ^key,
            select: {n.principal_id, n.body}
          )
        )

      assert Enum.sort(Enum.map(notified, &elem(&1, 0))) == Enum.sort([coach, assistant])

      assert Enum.all?(
               notified,
               &(elem(&1, 1) =~ "Sat 14 Nov 2026 at 18:30, St. Andrew's Hall has been cancelled")
             )
    end

    test "refusals", %{coordinator: c} do
      workshop = scheduled_fixture(c)

      assert {:error, :invalid_reason} =
               cancel(c, workshop, %{"reason" => String.duplicate("x", 501)})

      assert {:error, :invalid_reason} = cancel(c, workshop, %{"reason" => 7})

      member = staff_fixture("member")
      assert {:error, :forbidden} = cancel(member, workshop)
      assert {:error, :forbidden} = execute(:system, {:cancel_workshop, workshop.id, %{}})
      assert {:error, :not_found} = cancel(c, %{id: Ecto.UUID.generate()})
      assert {:error, :not_found} = cancel(c, %{id: "nope"})

      assert {:ok, _} = cancel(c, workshop)
      assert {:error, :already_cancelled} = cancel(c, workshop)

      finalised = scheduled_fixture(c, %{"date" => "2026-11-21"})
      force_status!(finalised.id, "finalised")
      assert {:error, :after_finalisation} = cancel(c, finalised)
    end
  end

  describe "afterwards" do
    test "a completion for a released hold is recorded and refunded in full", %{
      coordinator: c
    } do
      f = mixed_fixture(c)
      assert {:ok, _} = cancel(c, f.workshop)

      assert {:ok, %{outcome: :paid_after_close}} =
               execute(:stripe, {:complete_payment, Stripe.session(f.hold)})

      assert %IntakePayment{status: "paid"} = Repo.reload!(f.hold)
      assert %Intake{state: "returned"} = Repo.reload!(f.held)

      assert [%IntakeRefund{reason: "paid_after_close", amount_cents: 4000, status: "pending"}] =
               Repo.all(from(r in IntakeRefund, where: r.payment_id == ^f.hold.id))

      # Nobody's fee comes from it: they never had a seat.
      assert fees(f.held) == []
    end

    test "nothing happens to the workshop: no holds, confirms or check-ins", %{coordinator: c} do
      f = mixed_fixture(c)
      assert {:ok, _} = cancel(c, f.workshop)

      # No new hold from a link.
      assert {:error, _} = execute({:intake_link, f.tokens.three}, :start_payment)
      refute Repo.exists?(from(p in IntakePayment, where: p.intake_id == ^f.contacted.id))

      # No confirm, whether by the person or the console.
      assert {:error, _} = execute({:intake_link, f.tokens.one}, :confirm)

      assert {:error, :intake_closed} =
               execute({:staff, c}, {:confirm, f.workshop.id, f.paid.id, %{}})

      # No check-in on the workshop day.
      at_the_door = ~U[2026-11-14 18:00:00.000000Z]

      assert {:error, :check_in_closed} =
               execute({:staff, c}, {:check_in, f.workshop.id, f.paid.id}, at_the_door)

      # No Fast-track into it.
      person = waiting_person_fixture(~U[2025-06-01 12:00:00Z])

      assert {:error, :already_cancelled} =
               execute({:staff, c}, {:fast_track, f.workshop.id, {:waitlist_entry, person.id}})
    end

    test "no Batch, cutoff, finalisation or follow-up pass acts on it", %{coordinator: c} do
      # Contact from 20 October, so Batch 1 would go out at 10:00 that day.
      workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20"})
      waiting_people_fixture(3)
      assert {:ok, _} = cancel(c, workshop, %{}, now())

      for at <- [
            batch_1_at(),
            ~U[2026-11-11 19:00:00.000000Z],
            ~U[2026-11-15 12:00:00.000000Z],
            ~U[2026-11-16 12:00:00.000000Z]
          ] do
        BeginnersWorkshops.run_due_passes(clock: Clock.fixed(at))
      end

      refute Repo.exists?(from(b in Batch, where: b.workshop_id == ^workshop.id))
      refute Repo.exists?(from(i in Intake, where: i.workshop_id == ^workshop.id))

      assert {:ok, %{outcome: :not_due}} =
               execute(:system, {:send_due_batch, workshop.id}, batch_1_at())

      assert {:ok, %{outcome: :not_due}} =
               execute(
                 :system,
                 {:pass_payment_cutoff, workshop.id},
                 ~U[2026-11-11 19:00:00.000000Z]
               )

      assert {:ok, %{outcome: :not_due}} =
               execute(
                 :system,
                 {:finalise_attendance, workshop.id},
                 ~U[2026-11-15 12:00:00.000000Z]
               )

      assert {:ok, %{outcome: :not_due}} =
               execute(:system, {:send_follow_ups, workshop.id}, ~U[2026-11-16 12:00:00.000000Z])

      assert %BeginnersWorkshop{status: "cancelled"} = Repo.get!(BeginnersWorkshop, workshop.id)
    end

    test "deferred people get no Pre-workshop info or Follow-up, and nothing is owed",
         %{coordinator: c} do
      f = mixed_fixture(c)
      assert {:ok, _} = cancel(c, f.workshop)

      for at <- [
            ~U[2026-11-11 19:00:00.000000Z],
            ~U[2026-11-15 12:00:00.000000Z],
            ~U[2026-11-16 12:00:00.000000Z]
          ] do
        BeginnersWorkshops.run_due_passes(clock: Clock.fixed(at))
      end

      refute Repo.exists?(
               from(l in IntakeEmailLog,
                 join: i in Intake,
                 on: i.id == l.intake_id,
                 where:
                   i.workshop_id == ^f.workshop.id and
                     l.email_type in ~w(pre_workshop follow_up)
               )
             )

      {:ok, console} = WorkshopConsole.show(f.workshop.id, Clock.fixed(@now))

      scheduled =
        console.roster
        |> Map.values()
        |> List.flatten()
        |> Enum.flat_map(& &1.email_log)
        |> Enum.filter(& &1.scheduled)

      assert scheduled == []

      assert Enum.all?(
               console.roster |> Map.values() |> List.flatten(),
               &(&1.available_commands == [])
             )
    end
  end

  describe "moving people on" do
    test "a deferred person is fast-tracked into another workshop and confirms", %{
      coordinator: c
    } do
      f = mixed_fixture(c)
      assert {:ok, _} = cancel(c, f.workshop)

      other = scheduled_fixture(c, %{"date" => "2026-11-28", "contact_from" => "2026-10-20"})

      assert {:ok, %{id: intake_id}} =
               execute(
                 {:staff, c},
                 {:fast_track, other.id, {:waitlist_entry, f.paid.waitlist_id}}
               )

      assert [{"contact_confirm", "contact"}] =
               Repo.all(
                 from(l in IntakeEmailLog,
                   where: l.intake_id == ^intake_id,
                   select: {l.email_type, l.occasion}
                 )
               )

      token = IntakeLink.token(intake_id, 1)
      assert {:ok, %{outcome: :done}} = execute({:intake_link, token}, :confirm)

      assert %Intake{state: "paid", paid_via: "carried_fee"} = Repo.get!(Intake, intake_id)
      assert [%CarriedFee{status: "applied", applied_intake_id: ^intake_id}] = fees(f.paid)
    end
  end

  describe "the console and the list" do
    test "preview what Cancel would do, then show the cancellation", %{coordinator: c} do
      f = mixed_fixture(c)

      {:ok, before} = WorkshopConsole.show(f.workshop.id, Clock.fixed(@now))
      assert before.cancel_preview == %{deferred: 2, returned: 2, released: 1}
      assert before.cancellation == nil

      assert {:ok, _} = cancel(c, f.workshop, %{"reason" => "Hall flooded"})

      {:ok, console} = WorkshopConsole.show(f.workshop.id, Clock.fixed(@now))
      assert console.cancel_preview == nil
      assert %{at: @now, by: by, reason: "Hall flooded"} = console.cancellation
      assert is_binary(by) and by != ""
      assert console.workshop.stage == :cancelled
      assert [_, _, _, _] = console.roster.out
      assert [_ | _] = Enum.find(console.roster.out, &(&1.id == f.paid.id)).history

      %{upcoming: upcoming, past: past} =
        BeginnersWorkshops.list_workshops(clock: Clock.fixed(@now))

      refute Enum.any?(upcoming, &(&1.id == f.workshop.id))
      assert %{stage: :cancelled} = Enum.find(past, &(&1.id == f.workshop.id))
    end
  end

  # One contacted person who holds a `held` Carried Fee (from the import).
  defp contacted_holder_fixture(c) do
    workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => 1})
    [person] = waiting_people_fixture(1)

    assert {:ok, %{outcome: :created}} =
             execute(:system, {:import_carried_fee, person.id, "Yes"})

    assert {:ok, %{outcome: :sent}} =
             execute(:system, {:send_due_batch, workshop.id}, batch_1_at())

    [intake] = Repo.all(from(i in Intake, where: i.workshop_id == ^workshop.id))
    {workshop, [{intake, IntakeLink.token(intake.id, 1)}]}
  end
end
