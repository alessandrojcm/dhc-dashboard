defmodule Dhc.BeginnersWorkshops.AttendanceCorrectionsTest do
  @moduledoc """
  ALE-393: attendance corrections and Carried Fees at finalisation, through
  `Dhc.BeginnersWorkshops.execute/3` with fixed clocks and Stripe stubbed at
  the HTTP seam (`Dhc.BeginnersIntakeStripe`).

  `correct_attendance` (`beginners.workshops.manage`, after Attendance
  Finalisation) allows `attended ↔ no_show` and `no_show → deferred`; the
  standing and the Carried Fee follow, a Stripe-paid no-show corrected to
  deferred gets a `held` Carried Fee, and a no-show corrected to attended
  after the follow-up time gets the Follow-up then.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin (GMT),
  Batch 1 on 20 October; its Dublin day has ended at 15 November 00:00Z and
  the Follow-up is due at 10:00Z that morning.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Clock,
    Commands,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakeLink,
    IntakePayment,
    WorkshopConsole
  }

  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @day_ended ~U[2026-11-15 01:00:00.000000Z]
  @before_follow_up ~U[2026-11-15 09:59:59.000000Z]
  @follow_up ~U[2026-11-15 10:00:00.000000Z]
  @week_later ~U[2026-11-22 12:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator", %{first_name: "Clare"})}
  end

  defp execute(actor, command, at),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp correct(c, workshop, intake, to, at \\ @week_later, attrs \\ %{}),
    do:
      execute(
        {:staff, c},
        {:correct_attendance, workshop.id, intake.id, Map.put(attrs, "to", to)},
        at
      )

  defp token(intake), do: IntakeLink.token(intake.id, intake.link_generation)

  defp intake_of(workshop, person),
    do:
      Repo.one!(
        from(i in Intake, where: i.workshop_id == ^workshop.id and i.waitlist_id == ^person.id)
      )

  defp fees(person), do: Repo.all(from(f in CarriedFee, where: f.waitlist_id == ^person.id))
  defp fee!(person), do: person |> fees() |> then(fn [fee] -> fee end)

  defp occasions(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog,
          where: l.intake_id == ^intake.id,
          order_by: [asc: l.queued_at],
          select: l.occasion
        )
      )

  # The corrections in an Intake's history.
  defp events(intake),
    do:
      Repo.all(
        from(e in IntakeEvent,
          where: e.intake_id == ^intake.id and e.command == "correct_attendance"
        )
      )

  defp holder!(registered_at) do
    person = waiting_person_fixture(registered_at)

    assert {:ok, %{outcome: :created}} =
             execute(:system, {:import_carried_fee, person.id, "Yes"}, @now)

    person
  end

  defp pay!(intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token(intake)}, :start_payment, @now)

    row =
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(row)}, @now)

    Repo.reload!(row)
  end

  defp check_in!(intake, by) do
    intake
    |> Repo.reload!()
    |> Ecto.Changeset.change(checked_in_at: @now, checked_in_by_principal_id: by)
    |> Repo.update!()
  end

  # A finalised workshop: a Stripe payer and a Carried Fee holder who
  # attended, and a Stripe payer and a holder who didn't show.
  defp finalised!(%{coordinator: c}) do
    [stripe_in, stripe_out] =
      for day <- 1..2,
          do: waiting_person_fixture(DateTime.add(~U[2025-01-01 12:00:00Z], day, :day))

    [holder_in, holder_out] =
      for day <- 3..4, do: holder!(DateTime.add(~U[2025-01-01 12:00:00Z], day, :day))

    people = [stripe_in, stripe_out, holder_in, holder_out]
    workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => 4})

    assert {:ok, %{outcome: :sent}} =
             execute(:system, {:send_due_batch, workshop.id}, batch_1_at())

    [si, so, hi, ho] = Enum.map(people, &intake_of(workshop, &1))
    payment_in = pay!(si)
    payment_out = pay!(so)
    assert {:ok, %{outcome: :done}} = execute({:intake_link, token(hi)}, :confirm, @now)
    assert {:ok, %{outcome: :done}} = execute({:intake_link, token(ho)}, :confirm, @now)

    check_in!(si, c)
    check_in!(hi, c)

    assert {:ok, %{outcome: :finalised, attended: 2, no_show: 2}} =
             execute(:system, {:finalise_attendance, workshop.id}, @day_ended)

    %{
      coordinator: c,
      workshop: workshop,
      stripe_in: {stripe_in, Repo.reload!(si), payment_in},
      stripe_out: {stripe_out, Repo.reload!(so), payment_out},
      holder_in: {holder_in, Repo.reload!(hi)},
      holder_out: {holder_out, Repo.reload!(ho)}
    }
  end

  describe "the transition table" do
    test "declares the corrections for the Intake and the Carried Fee" do
      assert Commands.transition_allowed?(:intake, "attended", "no_show")
      assert Commands.transition_allowed?(:intake, "no_show", "attended")
      assert Commands.transition_allowed?(:intake, "no_show", "deferred")
      refute Commands.transition_allowed?(:intake, "attended", "deferred")
      refute Commands.transition_allowed?(:intake, "deferred", "attended")

      assert Commands.transition_allowed?(:carried_fee, "spent", "forfeited")
      assert Commands.transition_allowed?(:carried_fee, "forfeited", "spent")
      assert Commands.transition_allowed?(:carried_fee, "forfeited", "held")
      refute Commands.transition_allowed?(:carried_fee, "spent", "held")
      refute Commands.transition_allowed?(:carried_fee, "refunded", "held")
    end
  end

  describe "Attendance Finalisation" do
    test "spends an applied Carried Fee on attendance and forfeits it on a no-show", ctx do
      ctx = finalised!(ctx)
      {holder_in, hi} = ctx.holder_in
      {holder_out, ho} = ctx.holder_out

      assert %Intake{state: "attended"} = hi
      assert %Intake{state: "no_show"} = ho
      assert %CarriedFee{status: "spent"} = fee = fee!(holder_in)
      assert fee.applied_intake_id == hi.id
      assert %CarriedFee{status: "forfeited"} = fee = fee!(holder_out)
      assert fee.applied_intake_id == ho.id
    end
  end

  describe "correct_attendance" do
    setup ctx, do: finalised!(ctx)

    test "attended → no_show: standing removed, the spent fee forfeited, history, no email",
         ctx do
      {holder, intake} = ctx.holder_in
      before = occasions(intake)

      assert {:ok, %{state: "no_show", outcome: :done}} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show", @week_later, %{
                 "note" => "Left before the warm-up"
               })

      assert %Intake{state: "no_show"} = Repo.reload!(intake)
      assert %WaitlistEntry{status: "removed", removed_at: %DateTime{}} = Repo.reload!(holder)
      assert %CarriedFee{status: "forfeited"} = fee!(holder)
      assert occasions(intake) == before

      c = ctx.coordinator

      assert [
               %IntakeEvent{
                 command: "correct_attendance",
                 correction: "no_show",
                 actor_principal_id: ^c,
                 note: "Left before the warm-up"
               }
             ] = events(intake)

      # A repeat changes nothing.
      assert {:ok, %{outcome: :already_done}} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show")

      assert [_one] = events(intake)
    end

    test "a Stripe payer attended → no_show keeps no Carried Fee", ctx do
      {person, intake, _payment} = ctx.stripe_in

      assert {:ok, %{state: "no_show"}} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show")

      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert fees(person) == []
    end

    test "no_show → attended: standing attended, the forfeited fee spent again", ctx do
      {holder, intake} = ctx.holder_out

      assert {:ok, %{state: "attended"}} =
               correct(ctx.coordinator, ctx.workshop, intake, "attended")

      assert %WaitlistEntry{status: "attended"} = Repo.reload!(holder)
      assert %CarriedFee{status: "spent"} = fee = fee!(holder)
      assert fee.applied_intake_id == intake.id

      # And back again.
      assert {:ok, %{state: "no_show"}} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show")

      assert %CarriedFee{status: "forfeited"} = fee!(holder)
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(holder)
    end

    test "a no-show corrected to attended before the follow-up time gets it from the sweep",
         ctx do
      {_person, intake, _payment} = ctx.stripe_out

      assert {:ok, _} =
               correct(ctx.coordinator, ctx.workshop, intake, "attended", @before_follow_up)

      refute "follow_up" in occasions(intake)

      assert {:ok, %{outcome: :sent, follow_ups: 3}} =
               execute(:system, {:send_follow_ups, ctx.workshop.id}, @follow_up)

      assert "follow_up" in occasions(intake)
    end

    test "a no-show corrected to attended after the follow-up time gets the Follow-up then",
         ctx do
      {_person, intake, _payment} = ctx.stripe_out

      assert {:ok, %{outcome: :sent, follow_ups: 2}} =
               execute(:system, {:send_follow_ups, ctx.workshop.id}, @follow_up)

      assert {:ok, _} = correct(ctx.coordinator, ctx.workshop, intake, "attended")
      assert Enum.count(occasions(intake), &(&1 == "follow_up")) == 1

      # The sweep owes nobody anything now, and a second correction round
      # trip never sends it twice.
      assert {:ok, %{outcome: :sent, follow_ups: 0}} =
               execute(:system, {:send_follow_ups, ctx.workshop.id}, @week_later)

      assert {:ok, _} = correct(ctx.coordinator, ctx.workshop, intake, "no_show")
      assert {:ok, _} = correct(ctx.coordinator, ctx.workshop, intake, "attended")
      assert Enum.count(occasions(intake), &(&1 == "follow_up")) == 1
    end

    test "a Stripe-paid no_show → deferred: a held Carried Fee on its payment, waiting with priority, Deferred queued",
         ctx do
      {person, intake, payment} = ctx.stripe_out

      assert {:ok, %{state: "deferred"}} =
               correct(ctx.coordinator, ctx.workshop, intake, "deferred")

      assert %Intake{state: "deferred"} = Repo.reload!(intake)

      assert %CarriedFee{
               status: "held",
               origin: "deferral",
               amount_cents: 4000,
               applied_intake_id: nil
             } = fee = fee!(person)

      assert fee.payment_id == payment.id
      assert Repo.reload!(payment) == payment

      entry = Repo.reload!(person)
      assert entry.status == "waiting"
      assert entry.removed_at == nil
      assert entry.initial_registration_date == person.initial_registration_date

      assert "deferred" in occasions(intake)
      assert [%IntakeEvent{correction: "deferred"}] = events(intake)
    end

    test "a Carried-Fee-paid no_show → deferred holds the same fee again", ctx do
      {holder, intake} = ctx.holder_out
      %CarriedFee{id: id} = fee!(holder)

      assert {:ok, %{state: "deferred"}} =
               correct(ctx.coordinator, ctx.workshop, intake, "deferred")

      assert [%CarriedFee{id: ^id, status: "held", applied_intake_id: nil}] = fees(holder)
      assert %WaitlistEntry{status: "waiting"} = Repo.reload!(holder)
    end

    test "is refused once the person has been invited or has joined", ctx do
      {person, intake, _payment} = ctx.stripe_in

      assert {:ok, %{standing: "invited"}} =
               execute(
                 {:staff, ctx.coordinator},
                 {:invite, ctx.workshop.id, intake.id},
                 @week_later
               )

      assert {:error, :already_invited} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show")

      Repo.update!(Ecto.Changeset.change(Repo.reload!(person), status: "joined"))

      assert {:error, :already_invited} =
               correct(ctx.coordinator, ctx.workshop, intake, "no_show")

      assert %Intake{state: "attended"} = Repo.reload!(intake)
    end

    test "refuses a move outside the table, an unknown target and a non-manager", ctx do
      {_holder, attended} = ctx.holder_in
      {_person, no_show, _payment} = ctx.stripe_out

      assert {:error, :not_correctable} =
               correct(ctx.coordinator, ctx.workshop, attended, "deferred")

      assert {:ok, _} = correct(ctx.coordinator, ctx.workshop, no_show, "deferred")

      assert {:error, :not_correctable} =
               correct(ctx.coordinator, ctx.workshop, no_show, "attended")

      assert {:error, :invalid_correction} =
               correct(ctx.coordinator, ctx.workshop, attended, "paid")

      assert {:error, :invalid_correction} =
               execute(
                 {:staff, ctx.coordinator},
                 {:correct_attendance, ctx.workshop.id, attended.id, %{}},
                 @week_later
               )

      member = staff_fixture("member")
      assert {:error, :forbidden} = correct(member, ctx.workshop, attended, "no_show")
    end

    test "refuses a correction the person's record has moved past", ctx do
      {holder, intake} = ctx.holder_out

      # Their forfeited fee was refunded since (ALE-389's path).
      holder
      |> fee!()
      |> Ecto.Changeset.change(status: "refunded")
      |> Repo.update!()

      assert {:error, :not_correctable} =
               correct(ctx.coordinator, ctx.workshop, intake, "attended")

      assert %Intake{state: "no_show"} = Repo.reload!(intake)

      # A Stripe payer who already holds another live Carried Fee.
      {person, stripe_no_show, _payment} = ctx.stripe_out

      assert {:ok, %{outcome: :created}} =
               execute(:system, {:import_carried_fee, person.id, "Yes"}, @now)

      assert {:error, :not_correctable} =
               correct(ctx.coordinator, ctx.workshop, stripe_no_show, "deferred")

      assert [%CarriedFee{origin: "import"}] = fees(person)
    end

    test "refuses a correction to attended while the person has an open Intake elsewhere",
         ctx do
      {person, intake, _payment} = ctx.stripe_out

      Repo.update!(
        Ecto.Changeset.change(Repo.reload!(person), status: "waiting", removed_at: nil)
      )

      later = scheduled_fixture(ctx.coordinator, %{"date" => "2026-12-12"})
      intake_fixture!(later.id, Repo.reload!(person))

      assert {:error, :open_intake} = correct(ctx.coordinator, ctx.workshop, intake, "attended")
    end

    test "the finalised console offers the corrections the rule allows", ctx do
      {_holder, attended} = ctx.holder_in
      {_person, no_show, _payment} = ctx.stripe_out
      {_invited_person, invited, _} = ctx.stripe_in

      assert {:ok, _} =
               execute(
                 {:staff, ctx.coordinator},
                 {:invite, ctx.workshop.id, invited.id},
                 @week_later
               )

      assert {:ok, console} = WorkshopConsole.show(ctx.workshop.id, Clock.fixed(@week_later))
      rows = Map.new(console.roster.attended ++ console.roster.no_show, &{&1.id, &1})

      assert "correct_attendance" not in Enum.map(
               rows[invited.id].available_commands,
               &to_string/1
             )

      assert rows[invited.id].attendance_corrections == []
      assert :correct_attendance in rows[attended.id].available_commands
      assert rows[attended.id].attendance_corrections == ["no_show"]
      assert :correct_attendance in rows[no_show.id].available_commands
      assert rows[no_show.id].attendance_corrections == ["attended", "deferred"]
    end
  end

  describe "before finalisation" do
    test "is refused, and the console offers no correction", %{coordinator: c} do
      workshop = scheduled_fixture(c)
      intake = paid_person_fixture!(workshop.id)

      assert {:error, :before_finalisation} = correct(c, workshop, intake, "no_show", @now)

      force_intake_state!(intake.id, "attended")
      assert {:error, :before_finalisation} = correct(c, workshop, intake, "no_show", @now)

      assert {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      [row] = console.roster.attended
      refute :correct_attendance in row.available_commands
      assert row.attendance_corrections == []
    end
  end
end
