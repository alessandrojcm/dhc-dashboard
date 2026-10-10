defmodule Dhc.BeginnersWorkshops.CarriedFeesTest do
  @moduledoc """
  ALE-388: defer and confirm with a Carried Fee, through
  `Dhc.BeginnersWorkshops.execute/3` with fixed clocks and Stripe stubbed at
  the HTTP seam (`Dhc.BeginnersIntakeStripe`).

  Covers the ALE-367 Carried Fee table rows for defer and confirm (and the
  spend/forfeit at Attendance Finalisation), `defer` and `confirm` with their
  refusals, the `confirm` safe-view state, `start_payment`'s
  `:confirm_instead`, Fast-track after the cutoff, the cutoff pass leaving a
  holder's Intake open, re-registration, the console and the spreadsheet
  import.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin,
  Payment Cutoff Wednesday 11 November 18:30 UTC, Batch 1 on 20 October.
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
    FastTrackCandidates,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakePage,
    IntakePayment,
    WorkshopConsole
  }

  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]
  @after_cutoff ~U[2026-11-12 12:00:00.000000Z]
  # The workshop's Dublin day (14 November, GMT) has ended.
  @day_ended ~U[2026-11-15 01:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator", %{first_name: "Clare"})}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp command(c, name, workshop, intake, at \\ @now),
    do: execute({:staff, c}, {name, workshop.id, intake.id, %{}}, at)

  defp confirm(token, at \\ @now), do: execute({:intake_link, token}, :confirm, at)

  defp page(token, at \\ @now), do: IntakePage.show(token, Clock.fixed(at))

  defp pay!(token, intake, at \\ @now) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment, at)

    row =
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(row)}, at)

    Repo.reload!(row)
  end

  # A waiting person holding a `held` Carried Fee (made through the import's
  # command, the one way a fee exists without a deferral).
  defp holder!(registered_at \\ ~U[2024-06-01 12:00:00Z]) do
    person = waiting_person_fixture(registered_at)
    assert {:ok, %{outcome: :created}} = execute(:system, {:import_carried_fee, person.id, "Yes"})
    person
  end

  defp fees(%WaitlistEntry{id: id}), do: fees(id)

  defp fees(waitlist_id),
    do: Repo.all(from(f in CarriedFee, where: f.waitlist_id == ^waitlist_id))

  defp fee!(person), do: person |> fees() |> then(fn [fee] -> fee end)

  defp logs(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog, where: l.intake_id == ^intake.id, order_by: [asc: l.queued_at])
      )

  defp email_types(intake), do: intake |> logs() |> Enum.map(& &1.email_type)

  defp button_labels(%WaitlistEntry{email: email}) do
    from(j in Oban.Job,
      where: fragment("?->>'email'", j.args) == ^email,
      order_by: [asc: j.id],
      select: fragment("?->'data_variables'->>'BUTTON_LABEL'", j.args)
    )
    |> Repo.all()
  end

  defp intake_of(workshop, person),
    do:
      Repo.one!(
        from(i in Intake, where: i.workshop_id == ^workshop.id and i.waitlist_id == ^person.id)
      )

  defp token(intake),
    do: Dhc.BeginnersWorkshops.IntakeLink.token(intake.id, intake.link_generation)

  # A workshop (capacity `capacity`) whose Batch 1 contacted `people`.
  defp contacted!(c, people, capacity) do
    workshop =
      scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => capacity})

    assert {:ok, %{outcome: :sent}} =
             execute(:system, {:send_due_batch, workshop.id}, batch_1_at())

    {workshop, Enum.map(people, &intake_of(workshop, &1))}
  end

  describe "the transition table" do
    test "declares the Carried Fee moves, and paid → deferred for the Intake" do
      assert Commands.transitions().carried_fee == %{
               "held" => ~w(applied refunded forfeited),
               "applied" => ~w(held spent refunded forfeited)
             }

      for from <- ~w(spent refunded forfeited),
          to <- CarriedFee.statuses(),
          do: refute(Commands.transition_allowed?(:carried_fee, from, to))

      assert Commands.transition_allowed?(:intake, "paid", "deferred")
      refute Commands.transition_allowed?(:intake, "deferred", "paid")
    end

    test "a person holds at most one live Carried Fee" do
      person = holder!()

      assert {:ok, %{outcome: :already_held}} =
               execute(:system, {:import_carried_fee, person.id, "again"})

      assert_raise Ecto.ConstraintError, ~r/one_live_per_person/, fn ->
        Repo.insert!(%CarriedFee{
          waitlist_id: person.id,
          origin: "import",
          imported_paid_text: "x",
          status_changed_at: @now
        })
      end
    end
  end

  describe "defer" do
    test "a Stripe-paid Intake: deferred, a held Carried Fee on its payment, back to waiting with priority, Deferred queued",
         %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {workshop, [intake]} = contacted!(c, [person], 1)
      payment = pay!(token(intake), intake)

      assert {:ok, %{state: "deferred", outcome: :done}} = command(c, :defer, workshop, intake)

      assert %Intake{state: "deferred"} = Repo.reload!(intake)

      assert %CarriedFee{
               status: "held",
               origin: "deferral",
               amount_cents: 4000,
               currency: "eur",
               applied_intake_id: nil
             } = fee = fee!(person)

      assert fee.payment_id == payment.id
      # The original payment is never edited.
      assert Repo.reload!(payment) == payment

      entry = Repo.reload!(person)
      assert entry.status == "waiting"
      assert entry.initial_registration_date == person.initial_registration_date

      assert "deferred" in email_types(intake)

      assert [%IntakeEvent{command: "defer", actor_principal_id: ^c}] =
               Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

      # Repeating it changes nothing.
      assert {:ok, %{outcome: :already_done}} = command(c, :defer, workshop, intake)
      assert [_one] = fees(person)
    end

    test "a Carried-Fee-paid Intake returns the same fee to held", %{coordinator: c} do
      person = holder!()
      {workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, %{outcome: :done}} = confirm(token(intake))
      assert %CarriedFee{status: "applied"} = fee!(person)

      assert {:ok, %{state: "deferred"}} = command(c, :defer, workshop, intake)

      assert [%CarriedFee{status: "held", applied_intake_id: nil, origin: "import"}] =
               fees(person)
    end

    test "refuses a contacted Intake, a closed one, and a non-manager", %{coordinator: c} do
      [a, b] = waiting_people_fixture(2)
      {workshop, [contacted, lapsed]} = contacted!(c, [a, b], 2)
      force_intake_state!(lapsed.id, "lapsed")

      assert {:error, :intake_not_paid} = command(c, :defer, workshop, contacted)
      assert {:error, :intake_closed} = command(c, :defer, workshop, lapsed)
      assert {:error, :forbidden} = command(staff_fixture("coach"), :defer, workshop, contacted)
      assert fees(a) == [] and fees(b) == []
    end

    test "a deferred person's next contact asks them to confirm, and the preview marks them",
         %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {workshop, [intake]} = contacted!(c, [person], 1)
      pay!(token(intake), intake)
      assert {:ok, _} = command(c, :defer, workshop, intake)

      later =
        scheduled_fixture(c, %{
          "date" => "2026-12-05",
          "contact_from" => "2026-10-20",
          "capacity" => 4
        })

      {:ok, console} = WorkshopConsole.show(later.id, Clock.fixed(@now))
      assert [%{confirms: true}] = console.next_batch.people

      assert {:ok, %{outcome: :sent}} = execute(:system, {:send_due_batch, later.id}, @now)
      next = intake_of(later, person)

      assert %IntakeEmailLog{email_type: "contact_confirm", occasion: "contact"} =
               List.first(logs(next))

      assert List.last(button_labels(person)) == "Confirm my place"
      assert {:ok, %{state: :confirm, action: :confirm, fee_cents: nil}} = page(token(next))
    end
  end

  describe "confirm" do
    test "the person confirms in one click: paid via the Carried Fee, fee applied, no Stripe, Place confirmed queued",
         %{coordinator: c} do
      person = holder!()
      {workshop, [intake]} = contacted!(c, [person], 1)

      assert {:ok, %{state: :confirm}} = page(token(intake))
      assert {:ok, %{outcome: :done}} = confirm(token(intake))

      assert %Intake{state: "paid", paid_via: "carried_fee", paid_at: @now} =
               paid = Repo.reload!(intake)

      fee = fee!(person)
      assert %CarriedFee{status: "applied"} = fee
      assert fee.applied_intake_id == intake.id
      assert paid.carried_fee_id == fee.id

      assert Repo.all(from(p in IntakePayment, where: p.intake_id == ^intake.id)) == []
      assert email_types(intake) == ["contact_confirm", "place_confirmed_carried"]

      assert [%IntakeEvent{command: "confirm", actor_principal_id: nil}] =
               Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

      assert {:ok, %{state: :paid, fee_cents: nil}} = page(token(intake))

      # A second press is a no-op.
      assert {:ok, %{outcome: :already_done}} = confirm(token(intake))
      assert {:ok, view} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      assert view.workshop.seats.paid == 1
    end

    test "staff confirm on the person's behalf", %{coordinator: c} do
      person = holder!()
      {workshop, [intake]} = contacted!(c, [person], 1)

      assert {:ok, %{state: "paid", outcome: :done}} = command(c, :confirm, workshop, intake)

      assert [%IntakeEvent{command: "confirm", actor_principal_id: ^c}] =
               Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))
    end

    test "is refused with :no_carried_fee, :full and :already_paid", %{coordinator: c} do
      payer = waiting_person_fixture(~U[2024-01-01 12:00:00Z])
      person = holder!()
      {workshop, [payer_intake, intake]} = contacted!(c, [payer, person], 2)

      assert {:ok, _} =
               execute({:staff, c}, {:update_workshop, workshop.id, %{"capacity" => 1}})

      assert {:error, :no_carried_fee} = confirm(token(payer_intake))
      assert {:error, :confirm_instead} = execute({:intake_link, token(intake)}, :start_payment)

      pay!(token(payer_intake), payer_intake)

      assert {:ok, %{state: :full, action: :check_again}} = page(token(intake))
      assert {:error, :full} = confirm(token(intake))
      assert {:error, :full} = command(c, :confirm, workshop, intake)
      assert {:error, :already_paid} = command(c, :confirm, workshop, payer_intake)

      # The fee stays held and the Intake contacted: they may try again.
      assert %CarriedFee{status: "held"} = fee!(person)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end

    test "is not stopped by the Payment Cutoff, and queues Pre-workshop info at once after it",
         %{coordinator: c} do
      person = holder!()
      {workshop, [intake]} = contacted!(c, [person], 2)

      # The cutoff pass leaves a holder's Intake open.
      assert {:ok, %{outcome: :passed, lapsed: 0, returned: 0}} =
               execute(:system, {:pass_payment_cutoff, workshop.id}, @cutoff)

      assert %Intake{state: "contacted"} = Repo.reload!(intake)

      assert BeginnersWorkshops.run_due_passes(clock: Clock.fixed(@after_cutoff)).cutoff_lapsed ==
               0

      assert {:ok, %{state: :confirm}} = page(token(intake), @after_cutoff)
      assert {:ok, %{outcome: :done}} = confirm(token(intake), @after_cutoff)

      assert email_types(intake) == ["contact_confirm", "place_confirmed_carried", "pre_workshop"]
    end

    test "Attendance Finalisation spends an attended fee, forfeits a no-show's, and settles an unconfirmed holder",
         %{coordinator: c} do
      [attending, absent, unconfirmed] =
        for i <- 1..3, do: holder!(~U[2024-06-01 12:00:00Z] |> DateTime.add(i, :day))

      {workshop, [a, b, u]} = contacted!(c, [attending, absent, unconfirmed], 3)

      assert {:ok, _} = confirm(token(a))
      assert {:ok, _} = confirm(token(b))

      Repo.reload!(a)
      |> Ecto.Changeset.change(checked_in_at: @now, checked_in_by_principal_id: c)
      |> Repo.update!()

      assert {:ok, %{outcome: :finalised, attended: 1, no_show: 1, lapsed: 1}} =
               execute(:system, {:finalise_attendance, workshop.id}, @day_ended)

      assert %CarriedFee{status: "spent"} = fee!(attending)
      assert %CarriedFee{status: "forfeited"} = fee!(absent)
      # A lapse keeps the fee held (the person is removed, within retention).
      assert %CarriedFee{status: "held"} = fee!(unconfirmed)
      assert %Intake{state: "lapsed"} = Repo.reload!(u)
      assert {:error, :intake_closed} = confirm(token(u), @day_ended)
    end
  end

  describe "fast_track" do
    test "after the cutoff places a Carried Fee holder only", %{coordinator: c} do
      workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20"})
      person = holder!()
      payer = waiting_person_fixture(~U[2024-01-01 12:00:00Z])

      assert {:error, :after_cutoff} =
               execute(
                 {:staff, c},
                 {:fast_track, workshop.id, {:waitlist_entry, payer.id}},
                 @after_cutoff
               )

      assert {:ok, candidates} =
               FastTrackCandidates.search(workshop.id, nil, Clock.fixed(@after_cutoff))

      assert Enum.map(candidates, & &1.waitlist_id) == [person.id]
      assert [%{carried_fee: true}] = candidates

      assert {:ok, %{state: "contacted"}} =
               execute(
                 {:staff, c},
                 {:fast_track, workshop.id, {:waitlist_entry, person.id}},
                 @after_cutoff
               )

      intake = intake_of(workshop, person)
      assert email_types(intake) == ["contact_confirm"]
      assert {:ok, %{outcome: :done}} = confirm(token(intake), @after_cutoff)

      {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@after_cutoff))
      refute console.fast_track_open
      assert console.fast_track_holders_only
    end
  end

  describe "re-registration" do
    test "a removed person who registers again keeps a held Carried Fee" do
      person = holder!()

      assert {:ok, {:ok, _}} =
               Repo.transaction(fn -> Waitlist.change_standing(person.id, "removed") end)

      Repo.query!("UPDATE settings SET value = 'true' WHERE key = 'waitlist_open'")

      assert {:ok, %{id: id, status: "waiting"}} =
               Waitlist.create_entry(
                 %{
                   "firstName" => "Ada",
                   "lastName" => "Lovelace",
                   "email" => person.email,
                   "phoneNumber" => "+353 1 000 0000",
                   "dateOfBirth" => "1995-05-05",
                   "gender" => "woman (cis)",
                   "medicalConditions" => ""
                 },
                 now: @now
               )

      assert id == person.id
      assert %CarriedFee{status: "held"} = fee!(person)
      assert BeginnersWorkshops.carried_fees([person.id]) == %{person.id => "held"}
    end
  end

  describe "the console" do
    test "shows Carried Fee status on Intakes and lists holders who haven't confirmed",
         %{coordinator: c} do
      holder = holder!(~U[2024-01-01 12:00:00Z])
      payer = waiting_person_fixture(~U[2024-02-01 12:00:00Z])
      {workshop, [h, p]} = contacted!(c, [holder, payer], 2)

      {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      rows = Map.new(console.roster.asked, &{&1.id, &1})

      assert rows[h.id].carried_fee == "held"
      assert :confirm in rows[h.id].available_commands
      assert rows[p.id].carried_fee == nil
      refute :confirm in rows[p.id].available_commands
      assert [%{id: id}] = console.unconfirmed_carried_fees
      assert id == h.id

      assert {:ok, _} = confirm(token(h))
      {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      assert [%{carried_fee: "applied", available_commands: commands}] = console.roster.seated
      assert :defer in commands
      assert console.unconfirmed_carried_fees == []
    end
  end

  describe "the Waitlist spreadsheet import" do
    setup do
      Repo.query!("UPDATE settings SET value = 'false' WHERE key = 'waitlist_open'")
      :ok
    end

    test "creates a held Carried Fee for every row whose Paid cell is set, in the row's transaction" do
      sheet = File.read!("test/fixtures/waitlist_import/sample.tsv")

      assert {:ok, dry} = BeginnersWorkshops.import_waitlist(sheet, dry_run: true)
      assert dry.dry_run
      assert Repo.aggregate(CarriedFee, :count) == 0

      assert {:ok, report} = BeginnersWorkshops.import_waitlist(sheet)
      assert Enum.map(report.imported, & &1.row) == [2, 3, 6, 8]

      ciara = Repo.get_by!(WaitlistEntry, email: "ciara@example.com")
      dara = Repo.get_by!(WaitlistEntry, email: "dara@example.com")
      ada = Repo.get_by!(WaitlistEntry, email: "ada@example.com")

      assert %CarriedFee{
               status: "held",
               origin: "import",
               imported_paid_text: "Yes",
               payment_id: nil,
               stripe_payment_intent_id: nil,
               amount_cents: nil
             } = fee!(ciara)

      assert %CarriedFee{imported_paid_text: "€80"} = fee!(dara)
      assert fees(ada) == []
    end
  end
end
