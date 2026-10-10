defmodule Dhc.BeginnersWorkshops.CarriedFeeRefundsTest do
  @moduledoc """
  ALE-389: Carried Fee refunds and forfeits through
  `Dhc.BeginnersWorkshops.execute/3`, with fixed clocks and Stripe stubbed
  at the HTTP seam (`Dhc.BeginnersIntakeStripe`).

  Covers the remaining ALE-367 Carried Fee table rows (`refund_carried_fee`,
  `cancel_with_refund` on a Carried-Fee-paid Intake, `withdraw` with refund
  and with forfeit), the commands and their refusals, a failed refund's
  round trip (held again → Retry, Record manual refund, Forfeit), linking an
  imported fee to its Stripe payment, and the next contact after a refund.

  The workshop under test: `contacted_fixture/2`'s (fee €40, Batch 1 on
  20 October, cutoff 11 November).
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
    IntakePage,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    WorkshopConsole
  }

  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Email.Worker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator", %{first_name: "Clare"})}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp command(c, name, workshop, intake, attrs \\ %{}),
    do: execute({:staff, c}, {name, workshop.id, intake.id, attrs})

  defp refund_person(c, person, attrs \\ %{}),
    do: execute({:staff, c}, {:refund_carried_fee, person.id, attrs})

  defp token(intake),
    do: Dhc.BeginnersWorkshops.IntakeLink.token(intake.id, intake.link_generation)

  defp pay!(intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token(intake)}, :start_payment)

    row =
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))

    assert {:ok, %{outcome: :paid}} = execute(:stripe, {:complete_payment, Stripe.session(row)})
    Repo.reload!(row)
  end

  defp intake_of(workshop, person),
    do:
      Repo.one!(
        from(i in Intake, where: i.workshop_id == ^workshop.id and i.waitlist_id == ^person.id)
      )

  # A workshop (capacity `capacity`) that fast-tracked exactly `people`.
  defp contacted!(c, people, capacity) do
    workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => capacity})

    for person <- people do
      assert {:ok, %{state: "contacted"}} =
               execute({:staff, c}, {:fast_track, workshop.id, {:waitlist_entry, person.id}})
    end

    {workshop, Enum.map(people, &intake_of(workshop, &1))}
  end

  # A waiting person whose Stripe-paid Intake was deferred: a `held`
  # deferral Carried Fee on that payment. Returns `{person, deferred
  # Intake, payment}`.
  defp deferred_holder!(c) do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    {workshop, [intake]} = contacted!(c, [person], 1)
    payment = pay!(intake)
    assert {:ok, %{state: "deferred"}} = command(c, :defer, workshop, intake)
    {Repo.reload!(person), Repo.reload!(intake), payment}
  end

  # A waiting person holding an imported fee, linked to a Stripe payment.
  defp linked_holder!(c, payment_intent_id \\ "pi_imported") do
    person = waiting_person_fixture(~U[2024-06-01 12:00:00Z])
    assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "Paid 2025"})
    Stripe.stub_payment_intent(payment_intent_id, %{"amount_received" => 3500})

    assert {:ok, %{outcome: :done}} =
             execute(
               {:staff, c},
               {:link_carried_fee_payment, person.id, %{"payment_intent_id" => payment_intent_id}}
             )

    person
  end

  defp fees(person), do: Repo.all(from(f in CarriedFee, where: f.waitlist_id == ^person.id))
  defp fee!(person), do: person |> fees() |> then(fn [fee] -> fee end)

  defp fee_refunds(fee),
    do:
      Repo.all(
        from(r in IntakeRefund, where: r.carried_fee_id == ^fee.id, order_by: [asc: r.created_at])
      )

  defp email_types(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog,
          where: l.intake_id == ^intake.id,
          order_by: [asc: l.queued_at, asc: l.id],
          select: l.email_type
        )
      )

  defp notices(%WaitlistEntry{email: email}) do
    from(j in Oban.Job,
      where: j.worker == "Dhc.Email.Worker" and fragment("?->>'email'", j.args) == ^email,
      where: fragment("?->>'transactional_id'", j.args) == "beginnersWorkshopNotice",
      order_by: [asc: j.id],
      select: j.args
    )
    |> Repo.all()
  end

  defp console(workshop, at \\ @now) do
    {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(at))
    console
  end

  defp console_row(workshop, intake),
    do:
      workshop
      |> console()
      |> Map.fetch!(:roster)
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1.id == intake.id))

  defp submit(refund), do: execute(:system, {:submit_refund, refund.id})

  defp fail!(refund) do
    Stripe.fail_refund_create(400)
    assert {:ok, %{outcome: :failed}} = submit(refund)
    Repo.reload!(refund)
  end

  defp alerts(principal_id),
    do:
      Repo.all(
        from(n in Notification,
          where: n.principal_id == ^principal_id and like(n.notification_key, "%refund%")
        )
      )

  describe "the transition table" do
    test "a refunded Carried Fee goes back to held when its refund fails, and nowhere else" do
      assert Commands.transitions().carried_fee == %{
               "held" => ~w(applied refunded forfeited),
               "applied" => ~w(held spent refunded forfeited),
               "refunded" => ~w(held),
               "spent" => ~w(forfeited),
               "forfeited" => ~w(spent held)
             }

      for to <- ~w(applied spent refunded forfeited),
          do: refute(Commands.transition_allowed?(:carried_fee, "refunded", to))
    end
  end

  describe "refund_carried_fee" do
    test "a waiting holder: refunded in full against the original payment, Carried Fee refunded queued, standing and priority untouched",
         %{coordinator: c} do
      {person, deferred, payment} = deferred_holder!(c)
      before = Repo.reload!(person)

      assert {:ok, %{waitlist_id: id, carried_fee: %{status: "refunded"}, outcome: :done}} =
               refund_person(c, person)

      assert id == person.id

      fee = fee!(person)
      assert fee.status == "refunded"

      assert [
               %IntakeRefund{
                 status: "pending",
                 reason: "carried_fee_refunded",
                 amount_cents: 4000,
                 currency: "eur",
                 requested_by_principal_id: ^c
               } = refund
             ] = fee_refunds(fee)

      # Against the original payment, recorded on the Intake that paid it.
      assert refund.payment_id == payment.id
      assert refund.intake_id == deferred.id
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => refund.id})

      assert %WaitlistEntry{status: "waiting", initial_registration_date: priority} =
               Repo.reload!(person)

      assert priority == before.initial_registration_date

      assert "carried_fee_refunded" in email_types(deferred)
      assert [_deferred, refunded] = notices(person)
      assert refunded["data_variables"]["MESSAGE_HTML"] =~ "€40.00"

      # Stripe is asked against the original PaymentIntent, under the row's key.
      Stripe.stub_refund_create("succeeded")
      assert {:ok, %{outcome: :completed}} = submit(refund)
      assert_received {:refund_created, form, key}
      assert form["payment_intent"] == payment.stripe_payment_intent_id
      assert form["amount"] == "4000"
      assert key == "beginners-intake-refund:#{refund.id}"
      assert %CarriedFee{status: "refunded"} = fee!(person)
    end

    test "a contacted holder: the Intake stays contacted, its page switches to payment, and the next contact asks them to pay",
         %{coordinator: c} do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 2)
      assert {:ok, %{state: :confirm}} = IntakePage.show(token(intake), Clock.fixed(@now))
      assert :refund_carried_fee in console_row(workshop, intake).available_commands

      assert {:ok, %{state: "contacted", outcome: :done}} =
               command(c, :refund_carried_fee, workshop, intake, %{"note" => "Asked by email"})

      assert %Intake{state: "contacted"} = Repo.reload!(intake)
      assert %CarriedFee{status: "refunded", amount_cents: 3500} = fee = fee!(person)
      assert [%IntakeRefund{intake_id: intake_id, payment_id: nil} = refund] = fee_refunds(fee)
      assert intake_id == intake.id
      assert refund.stripe_payment_intent_id == "pi_imported"

      assert [%IntakeEvent{command: "refund_carried_fee", note: "Asked by email"}] =
               Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

      assert Enum.sort(email_types(intake)) == ["carried_fee_refunded", "contact_confirm"]
      assert {:ok, %{state: :pay}} = IntakePage.show(token(intake), Clock.fixed(@now))
      Stripe.stub_create()
      assert {:ok, _hold} = execute({:intake_link, token(intake)}, :start_payment)

      # Their next workshop asks them to pay normally.
      assert {:ok, _} = command(c, :decline, workshop, intake)

      later =
        scheduled_fixture(c, %{
          "date" => "2026-12-05",
          "contact_from" => "2026-10-20",
          "capacity" => 4
        })

      assert [%{confirms: false}] = console(later).next_batch.people
      assert {:ok, %{outcome: :sent}} = execute(:system, {:send_due_batch, later.id})
      assert email_types(intake_of(later, person)) == ["contact_pay"]
    end

    test "repeating it once the fee is refunded succeeds and does nothing again", %{
      coordinator: c
    } do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 2)

      assert {:ok, %{outcome: :done}} = command(c, :refund_carried_fee, workshop, intake)

      assert {:ok, %{state: "contacted", outcome: :already_done}} =
               command(c, :refund_carried_fee, workshop, intake)

      assert [_one_refund] = fee_refunds(fee!(person))

      assert [%IntakeEvent{command: "refund_carried_fee"}] =
               Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

      # From the Waitlist tab too, and a person who never held a fee is still refused.
      assert {:ok, %{outcome: :already_done}} = refund_person(c, person)
      assert [_one_refund] = fee_refunds(fee!(person))

      assert {:error, :no_carried_fee} =
               refund_person(c, waiting_person_fixture(~U[2025-02-01 12:00:00Z]))
    end

    test "the console offers it only when the boundary would refund: not to someone removed past retention",
         %{coordinator: c} do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 2)
      assert :refund_carried_fee in console_row(workshop, intake).available_commands

      Repo.update!(
        Ecto.Changeset.change(person, status: "removed", removed_at: ~U[2026-06-01 00:00:00Z])
      )

      refute :refund_carried_fee in console_row(workshop, intake).available_commands

      assert {:error, :fee_not_refundable} =
               command(c, :refund_carried_fee, workshop, intake)

      assert %CarriedFee{status: "held"} = fee!(person)

      assert IntakePolicy.check(:refund_carried_fee, %{
               state: "contacted",
               carried_fee: "held",
               fee_refundable: false
             }) == {:error, :fee_not_refundable}
    end

    test "a holder removed within retention may be refunded; one removed longer ago, or who attended, may not",
         %{coordinator: c} do
      recent = linked_holder!(c, "pi_recent")
      old = linked_holder!(c, "pi_old")
      attended = linked_holder!(c, "pi_attended")

      Repo.update!(
        Ecto.Changeset.change(recent, status: "removed", removed_at: ~U[2026-09-01 00:00:00Z])
      )

      Repo.update!(
        Ecto.Changeset.change(old, status: "removed", removed_at: ~U[2026-06-01 00:00:00Z])
      )

      Repo.update!(Ecto.Changeset.change(attended, status: "attended"))

      assert {:ok, %{outcome: :done}} = refund_person(c, recent)
      assert {:error, :fee_not_refundable} = refund_person(c, old)
      assert {:error, :fee_not_refundable} = refund_person(c, attended)
      assert %CarriedFee{status: "held"} = fee!(old)
    end

    test "is refused without a held fee, for a confirmed place, for an unlinked imported fee, and for a non-manager",
         %{coordinator: c} do
      nobody = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      assert {:error, :no_carried_fee} = refund_person(c, nobody)

      confirmed = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [confirmed], 1)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)
      assert {:error, :already_paid} = refund_person(c, confirmed)
      assert {:error, :already_paid} = command(c, :refund_carried_fee, workshop, intake)

      unlinked = waiting_person_fixture(~U[2025-03-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, unlinked.id, "Yes"})
      assert {:error, :payment_not_linked} = refund_person(c, unlinked)
      assert %CarriedFee{status: "held"} = fee!(unlinked)

      assert {:error, :forbidden} = refund_person(staff_fixture("coach"), unlinked)
      assert {:error, :person_not_found} = refund_person(c, %{id: "nope"})
      assert Repo.all(from(r in IntakeRefund, where: not is_nil(r.carried_fee_id))) == []
    end
  end

  describe "a failed Carried Fee refund" do
    test "holds the fee again, alerts the coordinators, and is retried", %{coordinator: c} do
      {person, deferred, _payment} = deferred_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))

      failed = fail!(refund)
      assert failed.status == "failed"
      assert %CarriedFee{status: "held", applied_intake_id: nil} = fee!(person)
      assert [alert] = alerts(c)
      assert alert.notification_key == "beginners-workshop-refund:#{refund.id}:failed"
      assert alert.body =~ "forfeit"

      # Needs attention on the original workshop's console offers Forfeit too.
      workshop = %{id: deferred.workshop_id}
      assert [%{id: id, carried_fee: true, forfeitable: true}] = console(workshop).failed_refunds
      assert id == refund.id

      assert {:ok, %{status: "pending", follows_refund_id: follows}} =
               execute({:staff, c}, {:retry_refund, workshop.id, refund.id})

      assert follows == refund.id
      assert %CarriedFee{status: "refunded"} = fee!(person)
      assert console(workshop).failed_refunds == []
    end

    test "stays refunded, still owed back, when the person has since paid an Intake through Stripe",
         %{coordinator: c} do
      {person, deferred, _payment} = deferred_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))

      # Their next contact asks them to pay, and they do, through Stripe.
      {workshop, [intake]} = contacted!(c, [person], 1)
      pay!(intake)
      assert %Intake{state: "paid", paid_via: "stripe"} = Repo.reload!(intake)

      fail!(refund)

      # A held fee beside a paid seat would be two entitlements: the fee
      # stays refunded and the money is still owed back.
      assert %CarriedFee{status: "refunded"} = fee!(person)
      assert [alert] = alerts(c)
      assert alert.body =~ "still owed back"
      refute alert.body =~ "forfeit"

      original = %{id: deferred.workshop_id}

      assert [%{id: id, carried_fee: true, forfeitable: false}] =
               console(original).failed_refunds

      assert id == refund.id

      assert {:error, :carried_fee_not_held} =
               execute({:staff, c}, {:forfeit_carried_fee, original.id, refund.id})

      # Deferring the Stripe-paid seat still works: it carries a new held fee.
      assert {:ok, %{state: "deferred"}} = command(c, :defer, workshop, intake)

      assert ["held", "refunded"] =
               person |> fees() |> Enum.map(& &1.status) |> Enum.sort()

      # Retry follows the failed refund up; the refunded fee stays refunded.
      assert {:ok, %{status: "pending", follows_refund_id: follows}} =
               execute({:staff, c}, {:retry_refund, original.id, refund.id})

      assert follows == refund.id
      assert console(original).failed_refunds == []
    end

    test "a refund.failed event holds the fee again too", %{coordinator: c} do
      person = linked_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))
      Stripe.stub_refund_create("pending")
      assert {:ok, %{outcome: :processing}} = submit(refund)

      object = Stripe.refund_object(refund.id, %{"status" => "failed"})
      assert {:ok, %{outcome: :failed}} = execute(:stripe, {:apply_refund_event, object})
      assert %CarriedFee{status: "held"} = fee!(person)
    end

    test "is recorded as a manual refund from the Waitlist tab, with no workshop", %{
      coordinator: c
    } do
      person = linked_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))
      assert refund.workshop_id == nil and refund.intake_id == nil
      fail!(refund)

      assert [alert] = alerts(c)
      assert alert.body =~ "€35.00"

      assert {:ok, %{status: "completed", method: "manual"}} =
               execute(
                 {:staff, c},
                 {:record_manual_refund, {:person, person.id}, refund.id, %{"note" => "Cash"}}
               )

      assert %CarriedFee{status: "refunded"} = fee!(person)

      assert {:error, :refund_followed_up} =
               execute({:staff, c}, {:forfeit_carried_fee, {:person, person.id}, refund.id})
    end

    test "is forfeited, only for a Carried Fee whose refund failed", %{coordinator: c} do
      person = linked_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))

      assert {:error, :refund_not_failed} =
               execute({:staff, c}, {:forfeit_carried_fee, {:person, person.id}, refund.id})

      fail!(refund)
      other = staff_fixture("beginners_coordinator")

      assert {:error, :refund_not_found} =
               execute(
                 {:staff, c},
                 {:forfeit_carried_fee, {:person, other_person_id()}, refund.id}
               )

      assert {:error, :forbidden} =
               execute(
                 {:staff, staff_fixture("coach")},
                 {:forfeit_carried_fee, {:person, person.id}, refund.id}
               )

      assert {:ok, %{status: "forfeited"}} =
               execute({:staff, other}, {:forfeit_carried_fee, {:person, person.id}, refund.id})

      assert %CarriedFee{status: "forfeited"} = fee!(person)

      assert {:error, :carried_fee_not_held} =
               execute({:staff, c}, {:retry_refund, {:person, person.id}, refund.id})
    end

    test "Forfeit refuses a payment's own refund", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {workshop, [intake]} = contacted!(c, [person], 1)
      pay!(intake)
      assert {:ok, _} = command(c, :cancel_with_refund, workshop, intake)
      [refund] = Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))
      fail!(refund)

      assert {:error, :not_a_carried_fee_refund} =
               execute({:staff, c}, {:forfeit_carried_fee, workshop.id, refund.id})

      assert [%{carried_fee: false}] = console(workshop).failed_refunds
    end

    test "a holder who confirms after the failure keeps the seat; the refund is no longer followed up",
         %{coordinator: c} do
      person = linked_holder!(c)
      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))
      fail!(refund)

      {_workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)

      assert {:error, :carried_fee_applied} =
               execute({:staff, c}, {:retry_refund, {:person, person.id}, refund.id})

      assert {:error, :carried_fee_applied} =
               execute({:staff, c}, {:forfeit_carried_fee, {:person, person.id}, refund.id})
    end
  end

  describe "cancel_with_refund on a Carried-Fee-paid Intake" do
    test "refunds the Carried Fee against its original payment; a failure holds it again",
         %{coordinator: c} do
      {person, _deferred, payment} = deferred_holder!(c)

      later =
        scheduled_fixture(c, %{"date" => "2026-12-05", "contact_from" => "2026-10-20"})

      assert {:ok, %{outcome: :sent}} = execute(:system, {:send_due_batch, later.id})
      intake = intake_of(later, person)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)

      assert {:ok, %{state: "cancelled_refunded"}} =
               command(c, :cancel_with_refund, later, intake)

      fee = fee!(person)
      assert fee.status == "refunded"

      assert [%IntakeRefund{reason: "cancelled_with_refund", amount_cents: 4000} = refund] =
               fee_refunds(fee)

      assert refund.payment_id == payment.id
      assert refund.intake_id == intake.id
      assert %WaitlistEntry{status: "waiting"} = Repo.reload!(person)
      assert "cancelled_with_refund" in email_types(intake)
      assert List.last(notices(person))["data_variables"]["MESSAGE_HTML"] =~ "€40.00"

      fail!(refund)
      assert %CarriedFee{status: "held", applied_intake_id: nil} = fee!(person)
      assert [%{id: id, carried_fee: true}] = console(later).failed_refunds
      assert id == refund.id
    end

    test "an unlinked imported fee can't be refunded until it is linked", %{coordinator: c} do
      person = waiting_person_fixture(~U[2024-06-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "Yes"})
      {workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)

      assert {:error, :payment_not_linked} = command(c, :cancel_with_refund, workshop, intake)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end
  end

  describe "withdraw with a Carried Fee" do
    test "a Carried-Fee-paid Intake needs the choice; forfeit makes the fee forfeited",
         %{coordinator: c} do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)

      assert {:error, :refund_choice_required} = command(c, :withdraw, workshop, intake)

      assert {:ok, %{state: "withdrawn"}} =
               command(c, :withdraw, workshop, intake, %{"refund" => false})

      assert %CarriedFee{status: "forfeited"} = fee = fee!(person)
      assert fee_refunds(fee) == []
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert "withdrawn_forfeited" in email_types(intake)
    end

    test "a Carried-Fee-paid Intake withdrawn with a refund refunds the fee", %{coordinator: c} do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, _} = execute({:intake_link, token(intake)}, :confirm)

      assert {:ok, %{state: "withdrawn"}} =
               command(c, :withdraw, workshop, intake, %{"refund" => true})

      assert %CarriedFee{status: "refunded"} = fee = fee!(person)
      assert [%IntakeRefund{reason: "withdrawn", amount_cents: 3500}] = fee_refunds(fee)
      assert "withdrawn_refunded" in email_types(intake)
      assert List.last(notices(person))["data_variables"]["MESSAGE_HTML"] =~ "€35.00"
    end

    test "the console row says when Withdraw needs the choice, for which money and how much, with the refund-timing hint",
         %{coordinator: c} do
      holder = linked_holder!(c)
      payer = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      plain = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      {workshop, [holding, paying, contacted]} = contacted!(c, [holder, payer, plain], 3)

      row = fn intake, at ->
        workshop
        |> console(at)
        |> Map.fetch!(:roster)
        |> Map.values()
        |> List.flatten()
        |> Enum.find(&(&1.id == intake.id))
      end

      # A contacted holder: their Carried Fee, whatever it originally took.
      assert %{
               refund_choice: %{source: :carried_fee, amount_cents: 3500, currency: "eur"},
               refund_timing_days_to_go: nil
             } = row.(holding, @now)

      assert %{refund_choice: nil, refund_timing_days_to_go: nil} = row.(contacted, @now)

      assert {:ok, _} = execute({:intake_link, token(holding)}, :confirm)
      pay!(paying)

      # Paid by the fee, or by Stripe: the full amount that payment took.
      assert %{refund_choice: %{source: :carried_fee, amount_cents: 3500}} =
               row.(holding, @now)

      assert %{refund_choice: %{source: :payment, amount_cents: 4000, currency: "eur"}} =
               row.(paying, @now)

      # Seven days or fewer to go, on the boundary clock (Dublin dates).
      for {at, days} <- [
            {~U[2026-11-07 00:30:00Z], 7},
            {~U[2026-11-06 23:30:00Z], nil},
            {~U[2026-11-13 12:00:00Z], 1}
          ] do
        assert %{refund_timing_days_to_go: ^days} = row.(paying, at)
      end

      assert %{refund_timing_days_to_go: nil} = row.(contacted, ~U[2026-11-13 12:00:00Z])
    end

    test "a contacted holder needs the choice too", %{coordinator: c} do
      person = linked_holder!(c)
      {workshop, [intake]} = contacted!(c, [person], 1)

      assert {:error, :refund_choice_required} = command(c, :withdraw, workshop, intake)

      assert {:ok, %{state: "declined"}} =
               command(c, :withdraw, workshop, intake, %{"refund" => false})

      assert %CarriedFee{status: "forfeited"} = fee!(person)
      assert "withdrawn_forfeited" in email_types(intake)
    end

    test "from the Waitlist tab with no Intake, even once removed", %{coordinator: c} do
      person = linked_holder!(c)

      assert {:error, :refund_choice_required} =
               execute({:staff, c}, {:withdraw, person.id, %{}})

      assert {:ok, %{status: "removed", outcome: :done}} =
               execute({:staff, c}, {:withdraw, person.id, %{"refund" => true}})

      assert %CarriedFee{status: "refunded"} = fee = fee!(person)
      assert [%IntakeRefund{reason: "withdrawn", intake_id: nil}] = fee_refunds(fee)
      assert [notice] = notices(person)
      assert notice["data_variables"]["MESSAGE_HTML"] =~ "€35.00"

      removed = linked_holder!(c, "pi_removed")

      Repo.update!(
        Ecto.Changeset.change(removed,
          status: "removed",
          removed_at: DateTime.truncate(@now, :second)
        )
      )

      assert {:ok, %{status: "removed", outcome: :done}} =
               execute({:staff, c}, {:withdraw, removed.id, %{"refund" => false}})

      assert %CarriedFee{status: "forfeited"} = fee!(removed)

      assert {:ok, %{outcome: :already_done}} =
               execute({:staff, c}, {:withdraw, removed.id, %{}})
    end

    test "someone without a Carried Fee needs no choice", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {workshop, [intake]} = contacted!(c, [person], 1)
      assert {:ok, %{state: "declined"}} = command(c, :withdraw, workshop, intake)
      assert email_types(intake) == ["contact_pay"]
    end
  end

  describe "link_carried_fee_payment" do
    test "links an imported fee to its Stripe payment with Stripe's amount; once linked it refunds through Stripe",
         %{coordinator: c} do
      person = waiting_person_fixture(~U[2024-06-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "€35 cash?"})
      Stripe.stub_payment_intent("pi_123", %{"amount_received" => 3500})

      assert {:ok, %{outcome: :done, amount_cents: 3500, stripe_payment_intent_id: "pi_123"}} =
               execute(
                 {:staff, c},
                 {:link_carried_fee_payment, person.id, %{"payment_intent_id" => " pi_123 "}}
               )

      assert %CarriedFee{
               status: "held",
               amount_cents: 3500,
               currency: "eur",
               imported_paid_text: "€35 cash?"
             } = fee!(person)

      assert {:ok, %{outcome: :already_done}} =
               execute(
                 {:staff, c},
                 {:link_carried_fee_payment, person.id, %{"payment_intent_id" => "pi_123"}}
               )

      assert {:error, :already_linked} =
               execute(
                 {:staff, c},
                 {:link_carried_fee_payment, person.id, %{"payment_intent_id" => "pi_other"}}
               )

      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))
      Stripe.stub_refund_create("succeeded")
      assert {:ok, %{outcome: :completed}} = submit(refund)
      assert_received {:refund_created, %{"payment_intent" => "pi_123", "amount" => "3500"}, _}
    end

    test "is refused with named reasons", %{coordinator: c} do
      link = fn person, id ->
        execute(
          {:staff, c},
          {:link_carried_fee_payment, person.id, %{"payment_intent_id" => id}}
        )
      end

      person = waiting_person_fixture(~U[2024-06-01 12:00:00Z])
      assert {:error, :no_carried_fee} = link.(person, "pi_1")
      assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "Yes"})

      assert {:error, :invalid_payment_reference} = link.(person, "ch_1")
      assert {:error, :invalid_payment_reference} = link.(person, "")

      Stripe.fail_payment_intent("pi_missing", 404)
      assert {:error, :stripe_payment_not_found} = link.(person, "pi_missing")

      Stripe.fail_payment_intent("pi_down", 503)
      assert {:error, :stripe_unavailable} = link.(person, "pi_down")

      Stripe.stub_payment_intent("pi_unpaid", %{"status" => "requires_payment_method"})
      assert {:error, :payment_not_succeeded} = link.(person, "pi_unpaid")

      Stripe.stub_payment_intent("pi_refunded", %{
        "latest_charge" => %{"id" => "ch_r", "amount_refunded" => 4000}
      })

      assert {:error, :payment_already_refunded} = link.(person, "pi_refunded")

      # A payment this system already tracks (an Intake payment's) is not an
      # imported fee's.
      {_person, _deferred, payment} = deferred_holder!(c)
      assert {:error, :payment_already_linked} = link.(person, payment.stripe_payment_intent_id)

      # A deferral's fee has its payment already.
      {deferred_person, _, _} = deferred_holder!(c)
      assert {:error, :not_imported} = link.(deferred_person, "pi_1")

      assert {:error, :forbidden} =
               execute(
                 {:staff, staff_fixture("coach")},
                 {:link_carried_fee_payment, person.id, %{"payment_intent_id" => "pi_1"}}
               )

      assert %CarriedFee{stripe_payment_intent_id: nil, amount_cents: nil} = fee!(person)
    end

    test "two people can't link the same payment", %{coordinator: c} do
      linked_holder!(c, "pi_shared")
      other = waiting_person_fixture(~U[2024-07-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, other.id, "Yes"})
      Stripe.stub_payment_intent("pi_shared")

      assert {:error, :payment_already_linked} =
               execute(
                 {:staff, c},
                 {:link_carried_fee_payment, other.id, %{"payment_intent_id" => "pi_shared"}}
               )
    end
  end

  describe "the Waitlist tab's Carried Fee view" do
    test "shows the fee, its payment, a failed refund and what may be done", %{coordinator: c} do
      unlinked = waiting_person_fixture(~U[2024-06-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, unlinked.id, "Yes"})

      assert {:ok, %{status: "held", linked: false, available: [:link_payment]}} =
               BeginnersWorkshops.carried_fee(unlinked.id, clock: Clock.fixed(@now))

      person = linked_holder!(c)

      assert {:ok, %{linked: true, available: [:refund], failed_refund: nil}} =
               BeginnersWorkshops.carried_fee(person.id, clock: Clock.fixed(@now))

      assert {:ok, _} = refund_person(c, person)
      [refund] = fee_refunds(fee!(person))

      assert {:ok, %{status: "refunded", available: []}} =
               BeginnersWorkshops.carried_fee(person.id, clock: Clock.fixed(@now))

      fail!(refund)

      assert {:ok, %{status: "held", failed_refund: %{id: id}, available: available}} =
               BeginnersWorkshops.carried_fee(person.id, clock: Clock.fixed(@now))

      assert id == refund.id
      assert available == [:retry, :manual, :forfeit]

      assert {:error, :no_carried_fee} =
               BeginnersWorkshops.carried_fee(waiting_person_fixture(~U[2025-01-01 12:00:00Z]).id)
    end
  end

  defp other_person_id, do: waiting_person_fixture(~U[2025-05-01 12:00:00Z]).id
end
