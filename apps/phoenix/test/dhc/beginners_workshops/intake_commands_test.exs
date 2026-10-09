defmodule Dhc.BeginnersWorkshops.IntakeCommandsTest do
  @moduledoc """
  ALE-386: the console Intake commands — `decline`, `resend_link` and
  `rotate_link` — through `Dhc.BeginnersWorkshops.execute/3` with a fixed
  clock, their shared plumbing (optional note, history, idempotent repeats,
  named refusals), and the console read model that carries each Intake's
  medical flag, link generation, email log, history and `availableCommands`.

  The workshop under test is `contacted_fixture/2`'s: Batch 1 on 20 October
  (window ends 27 October 23:59 Dublin), cutoff 11 November, fee €40.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures
  import Swoosh.TestAssertions

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakeLink,
    IntakePage,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    WorkshopConsole
  }

  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @after_window ~U[2026-10-28 12:00:00.000000Z]

  setup do
    coordinator =
      staff_fixture("beginners_coordinator", %{first_name: "Clare", last_name: "Coord"})

    %{coordinator: coordinator}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp command(coordinator, name, workshop, intake, attrs \\ %{}, at \\ @now),
    do: execute({:staff, coordinator}, {name, workshop.id, intake.id, attrs}, at)

  defp jobs(transactional_id),
    do:
      Enum.filter(
        all_enqueued(worker: Worker),
        &(&1.args["transactional_id"] == transactional_id)
      )

  defp logs(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog, where: l.intake_id == ^intake.id, order_by: [asc: l.queued_at])
      )

  defp events(intake), do: Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

  defp console_row(workshop, intake, at \\ @now) do
    {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(at))

    console.roster
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == intake.id))
  end

  defp pay!(token, intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)
    Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))
  end

  describe "decline" do
    test "closes a contacted Intake, keeps the person waiting at their priority and queues Declined",
         %{coordinator: c} do
      {workshop, [{intake, token}]} = contacted_fixture(c, 1)
      entry = Repo.get!(WaitlistEntry, intake.waitlist_id)

      assert {:ok, %{state: "declined", outcome: :done, link_generation: 1}} =
               command(c, :decline, workshop, intake, %{"note" => "  Replied: can't make it  "})

      assert %Intake{state: "declined"} = Repo.reload!(intake)

      assert %WaitlistEntry{status: "waiting", initial_registration_date: priority} =
               Repo.reload!(entry)

      assert priority == entry.initial_registration_date

      assert [%{args: %{"email" => email}}] = jobs("beginnersWorkshopNotice")
      assert email == entry.email

      assert [%{occasion: "contact"}, %{email_type: "declined", occasion: "declined"}] =
               logs(intake)

      assert [
               %IntakeEvent{
                 command: "decline",
                 actor_principal_id: ^c,
                 note: "Replied: can't make it",
                 occurred_at: @now
               }
             ] = events(intake)

      # The old link now says "no longer active".
      assert {:ok, %{state: :closed, closed_reason: :inactive}} =
               IntakePage.show(token, Clock.fixed(@now))
    end

    test "repeating it succeeds and does nothing again", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)
      assert {:ok, %{outcome: :done}} = command(c, :decline, workshop, intake)

      assert {:ok, %{state: "declined", outcome: :already_done}} =
               command(c, :decline, workshop, intake, %{"note" => "double click"})

      assert [_one] = jobs("beginnersWorkshopNotice")
      assert [_one] = events(intake)
    end

    test "refuses a paid Intake and a closed one with named reasons", %{coordinator: c} do
      {workshop, [{paid, _}, {lapsed, _}]} = contacted_fixture(c, 2)
      force_intake_state!(paid.id, "paid")
      force_intake_state!(lapsed.id, "lapsed")

      assert {:error, :already_paid} = command(c, :decline, workshop, paid)
      assert {:error, :intake_closed} = command(c, :decline, workshop, lapsed)
      assert jobs("beginnersWorkshopNotice") == []
      assert events(paid) == [] and events(lapsed) == []
    end

    test "returns a person staff removed while contacted to waiting", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)

      {:ok, _} =
        Repo.transaction(fn -> Dhc.Waitlist.change_standing(intake.waitlist_id, "removed") end)

      assert {:ok, %{outcome: :done}} = command(c, :decline, workshop, intake)

      assert %WaitlistEntry{status: "waiting", removed_at: nil} =
               Repo.get!(WaitlistEntry, intake.waitlist_id)
    end

    test "a live hold becomes releasing; a completion that arrives anyway is refunded in full",
         %{coordinator: c} do
      {workshop, [{intake, token}]} = contacted_fixture(c, 1)
      payment = pay!(token, intake)

      assert {:ok, %{outcome: :done}} = command(c, :decline, workshop, intake)
      assert %IntakePayment{status: "releasing"} = Repo.reload!(payment)

      # `releasing` no longer counts as a taken seat.
      assert %{seats: %{holds: 0, paid: 0, free: 1}} =
               BeginnersWorkshops.WorkshopProjection.view(
                 Repo.get!(BeginnersWorkshops.BeginnersWorkshop, workshop.id),
                 Map.fetch!(BeginnersWorkshops.WorkshopFacts.load([workshop.id]), workshop.id),
                 Clock.read(Clock.fixed(@now))
               )

      assert {:ok, %{outcome: :paid_after_close}} =
               execute(:stripe, {:complete_payment, Stripe.session(payment)})

      assert %IntakePayment{status: "paid"} = Repo.reload!(payment)
      assert %Intake{state: "declined"} = Repo.reload!(intake)

      assert [%IntakeRefund{reason: "paid_after_close", amount_cents: 4000, status: "pending"}] =
               Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))

      assert ["declined", "payment_refunded"] =
               intake
               |> logs()
               |> Enum.map(& &1.email_type)
               |> Enum.reject(&(&1 == "contact_pay"))
    end

    test "a hold Stripe expires after the decline is released", %{coordinator: c} do
      {workshop, [{intake, token}]} = contacted_fixture(c, 1)
      payment = pay!(token, intake)
      assert {:ok, %{outcome: :done}} = command(c, :decline, workshop, intake)

      assert {:ok, %{outcome: :released}} =
               execute(
                 :stripe,
                 {:release_payment, Stripe.session(payment, %{"status" => "expired"})}
               )

      assert %IntakePayment{status: "released"} = Repo.reload!(payment)
    end
  end

  describe "resend_link" do
    test "sends a contacted person's Contact email again with the same link", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)

      assert {:ok, %{state: "contacted", outcome: :done, link_generation: 1}} =
               command(c, :resend_link, workshop, intake)

      assert [%IntakeEvent{command: "resend_link", id: event_id, note: nil}] = events(intake)
      occasion = "resend_link:#{event_id}"

      assert [%{occasion: "contact"}, %{email_type: "contact_pay", occasion: ^occasion}] =
               logs(intake)

      assert [_contact, _again] = jobs = jobs("beginnersWorkshopAction")
      %{args: args} = Enum.max_by(jobs, & &1.id)
      assert args["data_variables"]["BUTTON_LABEL"] == "Pay for your place"
      assert :ok = perform_job(Worker, args)

      url = IntakeLink.url(IntakeLink.token(intake.id, 1))

      assert_email_sent(fn sent ->
        sent.provider_options.template.variables["BUTTON_URL"] == url
      end)
    end

    test "sends a paid person's Place confirmed email; each repeat sends again", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)
      force_intake_state!(intake.id, "paid")

      assert {:ok, %{outcome: :done}} = command(c, :resend_link, workshop, intake)
      assert {:ok, %{outcome: :done}} = command(c, :resend_link, workshop, intake)

      assert ["place_confirmed_paid", "place_confirmed_paid"] =
               intake |> logs() |> Enum.map(& &1.email_type) |> Enum.drop(1)

      assert [_, _] = events(intake)
    end

    test "refuses a closed Intake", %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)
      force_intake_state!(intake.id, "returned")

      assert {:error, :intake_closed} = command(c, :resend_link, workshop, intake)
      assert {:error, :intake_closed} = command(c, :rotate_link, workshop, intake)
      assert [_contact_only] = logs(intake)
    end
  end

  describe "rotate_link" do
    test "increments the link generation, retires the old link and sends the new one",
         %{coordinator: c} do
      {workshop, [{intake, old_token}]} = contacted_fixture(c, 1)

      assert {:ok, %{link_generation: 2, outcome: :done}} =
               command(c, :rotate_link, workshop, intake, %{
                 "note" => "Link forwarded to a friend"
               })

      new_token = IntakeLink.token(intake.id, 2)
      assert %Intake{link_generation: 2} = Repo.reload!(intake)

      assert {:error, :not_found} = IntakePage.show(old_token, Clock.fixed(@now))
      assert {:ok, %{state: :pay}} = IntakePage.show(new_token, Clock.fixed(@now))
      assert {:error, :not_found} = execute({:intake_link, old_token}, :start_payment)

      assert [_contact, _again] = jobs = jobs("beginnersWorkshopAction")
      %{args: args} = Enum.max_by(jobs, & &1.id)
      assert :ok = perform_job(Worker, args)

      url = IntakeLink.url(new_token)

      assert_email_sent(fn sent ->
        sent.provider_options.template.variables["BUTTON_URL"] == url
      end)

      assert [%IntakeEvent{command: "rotate_link", note: "Link forwarded to a friend"}] =
               events(intake)

      assert {:ok, %{link_generation: 3}} = command(c, :rotate_link, workshop, intake)
    end
  end

  describe "the shared plumbing" do
    test "a note must be text of at most 500 characters; a blank one is left out",
         %{coordinator: c} do
      {workshop, [{intake, _token}]} = contacted_fixture(c, 1)
      long = String.duplicate("x", 501)

      assert {:error, :invalid_note} = command(c, :decline, workshop, intake, %{"note" => long})
      assert {:error, :invalid_note} = command(c, :decline, workshop, intake, %{"note" => 7})
      assert %Intake{state: "contacted"} = Repo.reload!(intake)

      assert {:ok, _} = command(c, :resend_link, workshop, intake, %{"note" => "   "})
      assert [%IntakeEvent{note: nil}] = events(intake)
    end

    test "an Intake of another workshop, or no Intake, is not found", %{coordinator: c} do
      {workshop, [{intake, _}]} = contacted_fixture(c, 1)
      other = scheduled_fixture(c, %{"date" => "2026-12-05"})

      assert {:error, :intake_not_found} = command(c, :decline, other, intake)

      assert {:error, :intake_not_found} =
               execute({:staff, c}, {:decline, workshop.id, "not-a-uuid", %{}})

      assert {:error, :intake_not_found} =
               execute({:staff, c}, {:decline, workshop.id, Ecto.UUID.generate(), %{}})
    end

    test "only managers run Intake commands", %{coordinator: c} do
      {workshop, [{intake, _}]} = contacted_fixture(c, 1)
      coach = staff_fixture("coach")

      for name <- IntakePolicy.commands() do
        assert {:error, :forbidden} = command(coach, name, workshop, intake)
        assert {:error, :forbidden} = execute(:system, {name, workshop.id, intake.id, %{}})
      end

      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end
  end

  describe "the console Intake" do
    test "availableCommands agrees with the boundary's decision in every state", %{coordinator: c} do
      states = Intake.states()
      commands = IntakePolicy.commands()
      {workshop, intakes} = contacted_fixture(c, length(states) * length(commands))

      cases =
        for {state, i} <- Enum.with_index(states),
            {name, j} <- Enum.with_index(commands) do
          {intake, _token} = Enum.at(intakes, i * length(commands) + j)
          force_intake_state!(intake.id, state)
          {state, name, intake}
        end

      for {state, name, intake} <- cases do
        offered = console_row(workshop, intake).available_commands
        assert offered == IntakePolicy.available_commands(%{state: state})

        case command(c, name, workshop, intake) do
          {:ok, %{outcome: :done}} ->
            assert name in offered, "#{name} ran on #{state} but was not offered"

          {:ok, %{outcome: :already_done}} ->
            refute name in offered
            assert events(intake) == []

          {:error, reason} ->
            refute name in offered, "#{name} was offered on #{state} but refused: #{reason}"
            assert IntakePolicy.check(name, %{state: state}) == {:error, reason}
        end
      end
    end

    test "carries the medical flag, link generation, email log and history", %{coordinator: c} do
      {workshop, [{contacted, _}, {paid, _}]} = contacted_fixture(c, 2)
      force_intake_state!(paid.id, "paid")

      from(p in UserProfile, where: p.waitlist_id == ^paid.waitlist_id)
      |> Repo.update_all(set: [medical_conditions: "Asthma"])

      assert {:ok, _} =
               command(c, :rotate_link, workshop, contacted, %{"note" => "Lost the email"})

      row = console_row(workshop, contacted)
      assert %{medical: false, link_generation: 2, origin: "batch", batch_number: 1} = row

      assert [
               %{email_type: "contact_pay", scheduled: false},
               %{email_type: "contact_pay", scheduled: false, at: @now}
             ] = row.email_log

      assert [
               %{
                 command: "rotate_link",
                 actor: "Clare Coord",
                 note: "Lost the email",
                 occurred_at: @now
               }
             ] = row.history

      # A paid Intake still owed Pre-workshop info shows it as scheduled for the cutoff.
      paid_row = console_row(workshop, paid)
      assert paid_row.medical
      cutoff = workshop.payment_cutoff

      assert [
               %{email_type: "contact_pay"},
               %{email_type: "pre_workshop", scheduled: true, at: ^cutoff}
             ] =
               paid_row.email_log
    end

    test "a scheduled email follows the passes' occasions: per schedule, and the Follow-up",
         %{coordinator: c} do
      {workshop, [{paid, _}, {attended, _}]} = contacted_fixture(c, 2)
      force_intake_state!(paid.id, "paid")

      Repo.insert!(%IntakeEmailLog{
        intake_id: paid.id,
        email_type: "pre_workshop",
        occasion: "pre_workshop",
        queued_at: @now
      })

      refute Enum.any?(console_row(workshop, paid).email_log, & &1.scheduled)

      # After a reschedule, Pre-workshop info is owed again for the new schedule.
      from(w in BeginnersWorkshops.BeginnersWorkshop, where: w.id == ^workshop.id)
      |> Repo.update_all(set: [reschedule_count: 1])

      assert [%{email_type: "pre_workshop", scheduled: true}] =
               Enum.filter(console_row(workshop, paid).email_log, & &1.scheduled)

      # A finalised workshop owes its attended people the Follow-up.
      force_intake_state!(attended.id, "attended")
      force_status!(workshop.id, "finalised")
      follow_up_at = BeginnersWorkshops.WorkshopPolicy.follow_up_at(workshop)

      assert [%{email_type: "follow_up", scheduled: true, at: ^follow_up_at}] =
               Enum.filter(console_row(workshop, attended).email_log, & &1.scheduled)
    end

    test "Needs attention lists contacted people still unpaid after their window",
         %{coordinator: c} do
      {workshop, [{unpaid, _}, {paid, _}]} = contacted_fixture(c, 2)
      force_intake_state!(paid.id, "paid")

      assert {:ok, %{unpaid_after_window: []}} =
               WorkshopConsole.show(workshop.id, Clock.fixed(@now))

      assert {:ok, %{unpaid_after_window: [%{id: id, batch_number: 1, window_ends_at: ends}]}} =
               WorkshopConsole.show(workshop.id, Clock.fixed(@after_window))

      assert id == unpaid.id
      assert DateTime.compare(ends, @after_window) == :lt
    end
  end
end
