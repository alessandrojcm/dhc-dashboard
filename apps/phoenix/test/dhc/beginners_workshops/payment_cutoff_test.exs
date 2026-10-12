defmodule Dhc.BeginnersWorkshops.PaymentCutoffTest do
  @moduledoc """
  ALE-385: the Payment Cutoff pass (`pass_payment_cutoff`, run by the sweep)
  through `Dhc.BeginnersWorkshops.execute/3` with fixed clocks and Stripe
  stubbed at the HTTP seam (`Dhc.BeginnersIntakeStripe`).

  Paid Intakes get "Pre-workshop info" once; a `contacted` Intake lapses
  (standing `removed`) when seats were free or is returned (standing
  `waiting`, original priority) when the workshop was full, with no email;
  an Intake whose Seat Hold is live at the cutoff waits for Stripe and is
  settled by the same rule once the hold ends; a person paid after the
  cutoff gets Pre-workshop info at once.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin,
  Payment Cutoff Wednesday 11 November 18:30 UTC, Batch 1 on 20 October.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, Intake, IntakeEmailLog, IntakePayment}
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]
  # Ten minutes before the cutoff: a hold taken now is live at the cutoff.
  @late_hold_at ~U[2026-11-11 18:20:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp at(at), do: Clock.fixed(at)

  defp pass(workshop, at \\ @cutoff),
    do: BeginnersWorkshops.execute(:system, {:pass_payment_cutoff, workshop.id}, clock: at(at))

  defp pay(token, at),
    do: BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: at(at))

  defp complete(session, at),
    do: BeginnersWorkshops.execute(:stripe, {:complete_payment, session}, clock: at(at))

  defp release(session, at),
    do: BeginnersWorkshops.execute(:stripe, {:release_payment, session}, clock: at(at))

  defp payment!(intake),
    do:
      Repo.one!(
        from(p in IntakePayment,
          where: p.intake_id == ^intake.id,
          order_by: [desc: p.created_at],
          limit: 1
        )
      )

  defp paid!(token, intake, at \\ @now) do
    Stripe.stub_create()
    assert {:ok, _} = pay(token, at)
    assert {:ok, %{outcome: :paid}} = complete(Stripe.session(payment!(intake)), at)
  end

  defp pre_workshop_logs(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog,
          where: l.intake_id == ^intake.id and l.occasion == "pre_workshop"
        )
      )

  defp email_jobs, do: all_enqueued(worker: Worker)

  defp pre_workshop_jobs(entry) do
    Enum.filter(email_jobs(), fn job ->
      job.args["email"] == entry.email and job.args["subject"] =~ "See you on"
    end)
  end

  defp entry(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)

  describe "at the Payment Cutoff" do
    test "paid people get Pre-workshop info; unpaid people lapse when seats were free, with no email",
         %{coordinator: coordinator} do
      {workshop, [{paid, paid_token}, {first, _}, {second, _}]} =
        contacted_fixture(coordinator, 3)

      paid!(paid_token, paid)
      emails_before = length(email_jobs())

      assert {:ok, %{outcome: :passed, pre_workshop: 1, lapsed: 2, returned: 0, awaiting_hold: 0}} =
               pass(workshop)

      assert %Intake{state: "paid"} = Repo.reload!(paid)

      assert [%IntakeEmailLog{email_type: "pre_workshop", queued_at: @cutoff}] =
               pre_workshop_logs(paid)

      assert [%{args: %{"transactional_id" => "beginnersWorkshopAction"} = args}] =
               pre_workshop_jobs(entry(paid))

      assert args["data_variables"]["BUTTON_LABEL"] == "View my place"

      for intake <- [first, second] do
        assert %Intake{state: "lapsed"} = Repo.reload!(intake)
        assert %WaitlistEntry{status: "removed", removed_at: %DateTime{}} = entry(intake)
        assert pre_workshop_logs(intake) == []
      end

      # Only the one Pre-workshop info email was queued.
      assert length(email_jobs()) == emails_before + 1
    end

    test "unpaid people go back to the Waitlist with their original priority when the workshop was full",
         %{coordinator: coordinator} do
      {workshop, [{paid, paid_token}, {unpaid, _}]} = contacted_fixture(coordinator, 2)
      paid!(paid_token, paid)

      # The last seat is taken, so the unpaid person could only see "full".
      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:update_workshop, workshop.id, %{"capacity" => 1}},
                 clock: at(@now)
               )

      before = entry(unpaid)
      emails_before = length(email_jobs())

      assert {:ok, %{pre_workshop: 1, lapsed: 0, returned: 1}} = pass(workshop)

      assert %Intake{state: "returned"} = Repo.reload!(unpaid)
      after_return = entry(unpaid)
      assert after_return.status == "waiting"
      assert after_return.initial_registration_date == before.initial_registration_date
      assert length(email_jobs()) == emails_before + 1
    end

    test "the pass does nothing before the cutoff, and only the system may run it",
         %{coordinator: coordinator} do
      {workshop, [{intake, _}]} = contacted_fixture(coordinator, 1)

      assert {:ok, %{outcome: :not_due}} = pass(workshop, DateTime.add(@cutoff, -1))
      assert %Intake{state: "contacted"} = Repo.reload!(intake)

      assert {:error, :forbidden} =
               BeginnersWorkshops.execute(
                 {:staff, coordinator},
                 {:pass_payment_cutoff, workshop.id},
                 clock: at(@cutoff)
               )

      assert {:error, :not_found} =
               BeginnersWorkshops.execute(:system, {:pass_payment_cutoff, Ecto.UUID.generate()},
                 clock: at(@cutoff)
               )
    end

    test "running the pass twice is exactly-once", %{coordinator: coordinator} do
      {workshop, [{paid, paid_token}, {unpaid, _}]} = contacted_fixture(coordinator, 2)
      paid!(paid_token, paid)

      assert {:ok, %{pre_workshop: 1, lapsed: 1}} = pass(workshop)
      emails = length(email_jobs())

      assert {:ok, %{pre_workshop: 0, lapsed: 0, returned: 0, awaiting_hold: 0}} =
               pass(workshop, DateTime.add(@cutoff, 300))

      assert length(email_jobs()) == emails
      assert [_one] = pre_workshop_logs(paid)
      assert [_one] = pre_workshop_jobs(entry(paid))
      assert %Intake{state: "lapsed"} = Repo.reload!(unpaid)
    end

    test "a cancelled or finalised workshop is not passed", %{coordinator: coordinator} do
      {workshop, [{intake, _}]} = contacted_fixture(coordinator, 1)
      force_status!(workshop.id, "cancelled")

      assert {:ok, %{outcome: :not_due}} = pass(workshop)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end
  end

  describe "a Seat Hold live at the cutoff" do
    test "is left until Stripe ends it; a completed hold pays and gets Pre-workshop info at once",
         %{coordinator: coordinator} do
      {workshop, [{paying, paying_token}, {other, _}]} = contacted_fixture(coordinator, 2)
      Stripe.stub_create()
      assert {:ok, _} = pay(paying_token, @late_hold_at)

      # One of two seats is held, so the other person lapses; the holder waits.
      assert {:ok, %{lapsed: 1, awaiting_hold: 1, pre_workshop: 0}} = pass(workshop)
      assert %Intake{state: "contacted"} = Repo.reload!(paying)
      assert %Intake{state: "lapsed"} = Repo.reload!(other)
      assert %WaitlistEntry{status: "waiting"} = entry(paying)

      later = DateTime.add(@cutoff, 5 * 60)
      assert {:ok, %{outcome: :paid}} = complete(Stripe.session(payment!(paying)), later)

      assert %Intake{state: "paid"} = Repo.reload!(paying)
      assert [%IntakeEmailLog{queued_at: ^later}] = pre_workshop_logs(paying)
      assert [_one] = pre_workshop_jobs(entry(paying))

      assert {:ok, %{pre_workshop: 0, awaiting_hold: 0}} = pass(workshop, later)
      assert [_one] = pre_workshop_jobs(entry(paying))
    end

    test "a late payment on a workshop that is no longer scheduled gets no Pre-workshop info",
         %{coordinator: coordinator} do
      {workshop, [{paying, paying_token}]} = contacted_fixture(coordinator, 1)
      Stripe.stub_create()
      assert {:ok, _} = pay(paying_token, @late_hold_at)
      force_status!(workshop.id, "cancelled")

      assert {:ok, %{outcome: :paid}} =
               complete(Stripe.session(payment!(paying)), DateTime.add(@cutoff, 60))

      assert pre_workshop_logs(paying) == []
    end

    test "a released hold is settled by a later sweep with the same rule", %{
      coordinator: coordinator
    } do
      {workshop, [{holder, holder_token}]} = contacted_fixture(coordinator, 1)
      # A fast-tracked person who saw only "full" while the one seat was held.
      {late, _} = intake_fixture!(workshop.id, waiting_person_fixture(~U[2025-06-01 12:00:00Z]))

      Stripe.stub_create()
      assert {:ok, _} = pay(holder_token, @late_hold_at)

      assert {:ok, %{returned: 1, awaiting_hold: 1, lapsed: 0}} = pass(workshop)
      assert %Intake{state: "returned"} = Repo.reload!(late)
      assert %WaitlistEntry{status: "waiting"} = entry(late)
      assert %Intake{state: "contacted"} = Repo.reload!(holder)

      # Still held after its 30 minutes: Stripe has not ended it yet.
      assert {:ok, %{awaiting_hold: 1}} = pass(workshop, DateTime.add(@cutoff, 40 * 60))

      expired =
        Stripe.session(payment!(holder), %{"status" => "expired", "payment_status" => "unpaid"})

      released_at = DateTime.add(@cutoff, 45 * 60)
      assert {:ok, %{outcome: :released}} = release(expired, released_at)

      # The seat the holder kept is free now, so the holder lapses.
      assert {:ok, %{lapsed: 1, awaiting_hold: 0}} = pass(workshop, released_at)
      assert %Intake{state: "lapsed"} = Repo.reload!(holder)
      assert %WaitlistEntry{status: "removed"} = entry(holder)
    end
  end

  describe "the sweep" do
    test "runs the pass for workshops past their cutoff that still owe something", %{
      coordinator: coordinator
    } do
      {_workshop, [{paid, paid_token}, {unpaid, _}]} = contacted_fixture(coordinator, 2)
      paid!(paid_token, paid)

      assert %{cutoff_pre_workshop: 0, cutoff_lapsed: 0} =
               BeginnersWorkshops.run_due_passes(clock: at(DateTime.add(@cutoff, -1)))

      assert %{cutoff_pre_workshop: 1, cutoff_lapsed: 1, cutoff_returned: 0, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: at(@cutoff))

      assert %Intake{state: "lapsed"} = Repo.reload!(unpaid)

      assert %{cutoff_pre_workshop: 0, cutoff_lapsed: 0, failed: 0} =
               BeginnersWorkshops.run_due_passes(clock: at(DateTime.add(@cutoff, 300)))
    end
  end

  describe "the stage" do
    test "the list and the console show payment_closed after the cutoff", %{
      coordinator: coordinator
    } do
      {workshop, _intakes} = contacted_fixture(coordinator, 1)
      assert {:ok, _} = pass(workshop)

      %{upcoming: rows} = BeginnersWorkshops.list_workshops(clock: at(@cutoff))
      assert %{stage: :payment_closed} = Enum.find(rows, &(&1.id == workshop.id))

      assert {:ok, %{workshop: %{stage: :payment_closed}, roster: %{out: [%{state: "lapsed"}]}}} =
               BeginnersWorkshops.workshop_console(workshop.id, clock: at(@cutoff))
    end
  end
end
