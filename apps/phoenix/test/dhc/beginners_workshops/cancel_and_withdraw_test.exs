defmodule Dhc.BeginnersWorkshops.CancelAndWithdrawTest do
  @moduledoc """
  ALE-387: `cancel_with_refund` and `withdraw` through
  `Dhc.BeginnersWorkshops.execute/3` with a fixed clock and Stripe stubbed
  at the HTTP seam — the Intake and standing moves, the full refund against
  the paying payment, the refund-or-forfeit choice, the freed seat, the
  notices, every refusal, idempotent repeats, the console's
  `availableCommands`, and the Waitlist tab's withdraw by person.

  The workshop under test is `contacted_fixture/2`'s (fee €40, cutoff
  11 November).
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    WorkshopConsole
  }

  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp execute(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  defp command(c, name, workshop, intake, attrs \\ %{}),
    do: execute({:staff, c}, {name, workshop.id, intake.id, attrs})

  defp withdraw_person(c, entry_id, attrs \\ %{}),
    do: execute({:staff, c}, {:withdraw, entry_id, attrs})

  # A Stripe-paid Intake: a real hold, completed by Stripe.
  defp paid!(token, intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)

    payment =
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(payment)})

    Repo.reload!(payment)
  end

  defp paid_fixture(c) do
    {workshop, [{intake, token}]} = contacted_fixture(c, 1)
    payment = paid!(token, intake)
    {workshop, Repo.reload!(intake), payment}
  end

  defp entry(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)

  defp refunds(intake), do: Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))

  defp notices(intake) do
    Repo.all(
      from(l in IntakeEmailLog,
        where:
          l.intake_id == ^intake.id and l.email_type not in ~w(contact_pay place_confirmed_paid),
        select: {l.email_type, l.occasion}
      )
    )
  end

  defp events(intake), do: Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

  defp seats_taken(workshop) do
    {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
    length(console.roster.seated)
  end

  defp console_row(workshop, intake) do
    {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
    console.roster |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == intake.id))
  end

  describe "cancel_with_refund" do
    test "closes a paid Intake, refunds the payment in full, keeps the person's priority and queues the notice",
         %{coordinator: c} do
      {workshop, intake, payment} = paid_fixture(c)
      before = entry(intake)

      assert {:ok, %{state: "cancelled_refunded", outcome: :done}} =
               command(c, :cancel_with_refund, workshop, intake, %{"note" => "Wants money back"})

      assert %Intake{state: "cancelled_refunded"} = Repo.reload!(intake)

      assert [
               %IntakeRefund{
                 status: "pending",
                 method: "stripe",
                 reason: "cancelled_with_refund",
                 amount_cents: 4000,
                 currency: "eur",
                 requested_by_principal_id: ^c
               } = refund
             ] = refunds(intake)

      assert refund.payment_id == payment.id
      assert refund.stripe_payment_intent_id == payment.stripe_payment_intent_id
      refute IntakeRefund.automatic?(refund)
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => refund.id})

      assert %WaitlistEntry{status: "waiting", initial_registration_date: priority} =
               entry(intake)

      assert priority == before.initial_registration_date

      assert [{"cancelled_with_refund", "cancelled_with_refund"}] = notices(intake)

      assert [email] =
               Enum.filter(
                 all_enqueued(worker: Worker),
                 &(&1.args["transactional_id"] == "beginnersWorkshopNotice")
               )

      assert email.args["data_variables"]["MESSAGE_HTML"] =~ "€40.00"

      assert [%IntakeEvent{command: "cancel_with_refund", note: "Wants money back"}] =
               events(intake)
    end

    test "repeating it succeeds and does nothing again", %{coordinator: c} do
      {workshop, intake, _payment} = paid_fixture(c)
      assert {:ok, %{outcome: :done}} = command(c, :cancel_with_refund, workshop, intake)

      assert {:ok, %{state: "cancelled_refunded", outcome: :already_done}} =
               command(c, :cancel_with_refund, workshop, intake)

      assert [_one] = refunds(intake)
      assert [_one] = notices(intake)
      assert [_one] = events(intake)
    end

    test "refuses unpaid and closed Intakes with named reasons", %{coordinator: c} do
      {workshop, [{contacted, _}, {lapsed, _}]} = contacted_fixture(c, 2)
      force_intake_state!(lapsed.id, "lapsed")

      assert {:error, :intake_not_paid} = command(c, :cancel_with_refund, workshop, contacted)
      assert {:error, :intake_closed} = command(c, :cancel_with_refund, workshop, lapsed)
      assert Repo.all(IntakeRefund) == []
    end

    test "a paid Intake with no payment that took money has nothing to refund",
         %{coordinator: c} do
      {workshop, [{intake, _}]} = contacted_fixture(c, 1)
      force_intake_state!(intake.id, "paid")

      assert {:error, :nothing_to_refund} = command(c, :cancel_with_refund, workshop, intake)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "a refund already requested for the payment is refused, not doubled", %{coordinator: c} do
      {workshop, intake, payment} = paid_fixture(c)

      Repo.insert!(%IntakeRefund{
        id: Ecto.UUID.generate(),
        workshop_id: workshop.id,
        intake_id: intake.id,
        payment_id: payment.id,
        reason: "cancelled_with_refund",
        amount_cents: 4000,
        idempotency_key: "beginners-intake-refund:#{Ecto.UUID.generate()}",
        requested_at: @now
      })

      assert {:error, :already_requested} = command(c, :cancel_with_refund, workshop, intake)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "needs beginners.workshops.manage", %{coordinator: _c} do
      coordinator = staff_fixture("beginners_coordinator")
      {workshop, intake, _payment} = paid_fixture(coordinator)
      member = staff_fixture("member")

      assert {:error, :forbidden} = command(member, :cancel_with_refund, workshop, intake)
    end
  end

  describe "withdraw on the console" do
    test "a contacted Intake closes as declined, its hold stops counting and nobody is emailed",
         %{coordinator: c} do
      {workshop, [{intake, token}]} = contacted_fixture(c, 1)
      Stripe.stub_create()
      assert {:ok, _} = execute({:intake_link, token}, :start_payment)

      assert {:ok, %{state: "declined", outcome: :done}} =
               command(c, :withdraw, workshop, intake, %{"refund" => true})

      assert %WaitlistEntry{status: "removed", removed_at: %DateTime{}} = entry(intake)

      assert [%IntakePayment{status: "releasing"}] =
               Repo.all(from(p in IntakePayment, where: p.intake_id == ^intake.id))

      assert notices(intake) == []
      assert Repo.all(IntakeRefund) == []
      assert [%IntakeEvent{command: "withdraw"}] = events(intake)
    end

    test "a paid Intake needs the refund-or-forfeit choice", %{coordinator: c} do
      {workshop, intake, _payment} = paid_fixture(c)

      assert {:error, :refund_choice_required} = command(c, :withdraw, workshop, intake)

      assert {:error, :invalid_refund_choice} =
               command(c, :withdraw, workshop, intake, %{"refund" => "yes"})

      assert %Intake{state: "paid"} = Repo.reload!(intake)
      assert %WaitlistEntry{status: "waiting"} = entry(intake)
      assert events(intake) == []
    end

    test "withdraw with refund: withdrawn, removed, refunded in full and told so",
         %{coordinator: c} do
      {workshop, intake, payment} = paid_fixture(c)

      assert {:ok, %{state: "withdrawn", outcome: :done}} =
               command(c, :withdraw, workshop, intake, %{
                 "refund" => true,
                 "note" => "Moving away"
               })

      assert %WaitlistEntry{status: "removed"} = entry(intake)

      assert [%IntakeRefund{reason: "withdrawn", amount_cents: 4000, payment_id: payment_id}] =
               refunds(intake)

      assert payment_id == payment.id
      assert [{"withdrawn_refunded", "withdrawn"}] = notices(intake)
      assert [%IntakeEvent{command: "withdraw", note: "Moving away"}] = events(intake)
    end

    test "withdraw with forfeit: withdrawn, removed, nothing refunded, forfeited notice",
         %{coordinator: c} do
      {workshop, intake, _payment} = paid_fixture(c)

      assert {:ok, %{state: "withdrawn"}} =
               command(c, :withdraw, workshop, intake, %{"refund" => false})

      assert %WaitlistEntry{status: "removed"} = entry(intake)
      assert refunds(intake) == []
      assert [{"withdrawn_forfeited", "withdrawn"}] = notices(intake)

      assert {:ok, %{outcome: :already_done}} =
               command(c, :withdraw, workshop, intake, %{"refund" => true})

      assert refunds(intake) == []
    end

    test "refuses closed Intakes", %{coordinator: c} do
      {workshop, [{lapsed, _}]} = contacted_fixture(c, 1)
      force_intake_state!(lapsed.id, "lapsed")

      assert {:error, :intake_closed} = command(c, :withdraw, workshop, lapsed)
    end

    test "needs beginners.waitlist.manage", %{coordinator: c} do
      {workshop, [{intake, _}]} = contacted_fixture(c, 1)
      assert {:error, :forbidden} = command(staff_fixture("coach"), :withdraw, workshop, intake)
    end
  end

  describe "any exit from paid frees the seat at once" do
    for {name, attrs} <- [
          cancel_with_refund: %{},
          withdraw: %{"refund" => true},
          withdraw: %{"refund" => false}
        ] do
      test "#{name} #{inspect(attrs)}", %{coordinator: c} do
        {workshop, intake, _payment} = paid_fixture(c)

        {waiting, token} =
          intake_fixture!(workshop.id, waiting_person_fixture(~U[2025-06-01 12:00:00Z]))

        assert seats_taken(workshop) == 1
        Stripe.stub_create()
        assert {:error, :full} = execute({:intake_link, token}, :start_payment)

        assert {:ok, _} =
                 command(c, unquote(name), workshop, intake, unquote(Macro.escape(attrs)))

        assert seats_taken(workshop) == 0
        assert {:ok, _} = execute({:intake_link, token}, :start_payment)

        assert Repo.exists?(
                 from(p in IntakePayment,
                   where: p.intake_id == ^waiting.id and p.status == "open"
                 )
               )
      end
    end
  end

  describe "withdraw from the Waitlist tab" do
    test "a waiting person with no Intake is removed and nobody is emailed", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-03-01 12:00:00Z])

      assert {:ok, %{status: "removed", intake: nil, outcome: :done, waitlist_id: id}} =
               withdraw_person(c, person.id, %{"refund" => false})

      assert id == person.id
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert all_enqueued(worker: Worker) == []

      assert {:ok, %{status: "removed", outcome: :already_done}} = withdraw_person(c, person.id)
    end

    test "an attended person may leave; an invited one is refused", %{coordinator: c} do
      attended = waiting_person_fixture(~U[2025-03-01 12:00:00Z])
      invited = waiting_person_fixture(~U[2025-03-02 12:00:00Z])

      Repo.update!(Ecto.Changeset.change(attended, status: "attended"))
      Repo.update!(Ecto.Changeset.change(invited, status: "invited"))

      assert {:ok, %{status: "removed"}} = withdraw_person(c, attended.id)
      assert {:error, :already_invited} = withdraw_person(c, invited.id)
      assert %WaitlistEntry{status: "invited"} = Repo.reload!(invited)
    end

    test "a person with a paid Intake goes through the same rule as the console",
         %{coordinator: c} do
      {_workshop, intake, _payment} = paid_fixture(c)

      assert {:error, :refund_choice_required} = withdraw_person(c, intake.waitlist_id)

      assert {:ok,
              %{
                status: "removed",
                outcome: :done,
                intake: %{id: intake_id, state: "withdrawn", outcome: :done}
              }} = withdraw_person(c, intake.waitlist_id, %{"refund" => true, "note" => "Asked"})

      assert intake_id == intake.id
      assert [%IntakeRefund{reason: "withdrawn"}] = refunds(intake)
      assert [{"withdrawn_refunded", "withdrawn"}] = notices(intake)

      assert [%IntakeEvent{command: "withdraw", note: "Asked", actor_principal_id: ^c}] =
               events(intake)

      # Now there is no open Intake: the repeat is the standing's.
      assert {:ok, %{status: "removed", intake: nil, outcome: :already_done}} =
               withdraw_person(c, intake.waitlist_id, %{"refund" => true})

      assert [_one] = refunds(intake)
    end

    test "a person with a contacted Intake: declined and removed", %{coordinator: c} do
      {_workshop, [{intake, _}]} = contacted_fixture(c, 1)

      assert {:ok, %{status: "removed", intake: %{state: "declined"}}} =
               withdraw_person(c, intake.waitlist_id)

      assert %Intake{state: "declined"} = Repo.reload!(intake)
    end

    test "an unknown person is person_not_found", %{coordinator: c} do
      assert {:error, :person_not_found} = withdraw_person(c, Ecto.UUID.generate())
      assert {:error, :person_not_found} = withdraw_person(c, "nope")
    end

    test "needs beginners.waitlist.manage", %{coordinator: c} do
      person = waiting_person_fixture(~U[2025-03-01 12:00:00Z])
      _ = c
      assert {:error, :forbidden} = withdraw_person(staff_fixture("coach"), person.id)
      assert %WaitlistEntry{status: "waiting"} = Repo.reload!(person)
    end
  end

  describe "the console offers them" do
    test "availableCommands follows IntakePolicy for each state", %{coordinator: c} do
      {workshop, intake, _payment} = paid_fixture(c)

      assert console_row(workshop, intake).available_commands ==
               [:defer, :cancel_with_refund, :withdraw, :resend_link, :rotate_link]

      {:ok, _} = command(c, :cancel_with_refund, workshop, intake)
      assert console_row(workshop, intake).available_commands == []
    end

    test "IntakePolicy decides cancel_with_refund and withdraw by state and how it was paid" do
      assert IntakePolicy.check(:cancel_with_refund, %{state: "paid", paid_via: "stripe"}) == :ok

      assert IntakePolicy.check(:cancel_with_refund, %{state: "paid", paid_via: "carried_fee"}) ==
               :ok

      assert IntakePolicy.check(:cancel_with_refund, %{state: "cancelled_refunded"}) ==
               :already_done

      assert IntakePolicy.check(:cancel_with_refund, %{state: "contacted"}) ==
               {:error, :intake_not_paid}

      assert IntakePolicy.check(:withdraw, %{state: "contacted"}) == :ok
      assert IntakePolicy.check(:withdraw, %{state: "paid", paid_via: "stripe"}) == :ok
      assert IntakePolicy.check(:withdraw, %{state: "withdrawn"}) == :already_done
      assert IntakePolicy.check(:withdraw, %{state: "declined"}) == {:error, :intake_closed}

      assert IntakePolicy.available_commands(%{state: "contacted"}) ==
               [:decline, :withdraw, :resend_link, :rotate_link]
    end
  end
end
