defmodule Dhc.BeginnersWorkshops.ReOfferTest do
  @moduledoc """
  A Re-offer (`CONTEXT.md`): `re_offer` through
  `Dhc.BeginnersWorkshops.execute/3` with fixed clocks and Stripe stubbed at
  the HTTP seam (`Dhc.BeginnersIntakeStripe`).

  A person whose Intake lapsed or was returned at the Payment Cutoff gets a
  new `contacted` Intake in the same workshop, the Contact email with the
  workshop start as `{{windowEnd}}`, and may pay until the workshop starts.
  The cutoff pass leaves the new Intake alone; Attendance Finalisation
  settles it if unpaid; a reschedule past its contact time makes it
  ordinary again.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin (GMT,
  so 18:30 UTC), Payment Cutoff Wednesday 11 November 18:30 UTC, Batch 1 on
  20 October.
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
    IntakeLink,
    IntakePayment
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @cutoff ~U[2026-11-11 18:30:00.000000Z]
  @after_cutoff ~U[2026-11-12 12:00:00.000000Z]
  @start ~U[2026-11-14 18:30:00.000000Z]
  @day_after ~U[2026-11-15 09:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp at(at), do: Clock.fixed(at)

  defp re_offer(staff, workshop, intake, attrs \\ %{}, at \\ @after_cutoff),
    do:
      BeginnersWorkshops.execute({:staff, staff}, {:re_offer, workshop.id, intake.id, attrs},
        clock: at(at)
      )

  defp pass(workshop, at \\ @cutoff),
    do: BeginnersWorkshops.execute(:system, {:pass_payment_cutoff, workshop.id}, clock: at(at))

  defp pay(token, at),
    do: BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: at(at))

  defp complete(session, at),
    do: BeginnersWorkshops.execute(:stripe, {:complete_payment, session}, clock: at(at))

  defp paid!(token, intake, at) do
    Stripe.stub_create()
    assert {:ok, _} = pay(token, at)
    assert {:ok, %{outcome: :paid}} = complete(Stripe.session(payment!(intake)), at)
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

  defp capacity!(staff, workshop, capacity, at \\ @now) do
    assert {:ok, _} =
             BeginnersWorkshops.execute(
               {:staff, staff},
               {:update_workshop, workshop.id, %{"capacity" => capacity}},
               clock: at(at)
             )
  end

  defp entry(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)
  defp token(intake), do: IntakeLink.token(intake.id, intake.link_generation)
  defp events(intake), do: Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

  defp email_jobs, do: all_enqueued(worker: Worker)

  defp jobs_to(intake), do: Enum.filter(email_jobs(), &(&1.args["email"] == entry(intake).email))

  # The contact template as a paragraph of `names` placeholders joined by " / ".
  defp contact_template!(names) do
    content =
      names
      |> Enum.map(&%{"type" => "placeholder", "attrs" => %{"name" => &1}})
      |> Enum.intersperse(%{"type" => "text", "text" => " / "})

    Repo.update_all(Template |> where(email_type: "contact_pay"),
      set: [
        body: %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]}
      ]
    )
  end

  defp console_rows(workshop, at \\ @after_cutoff) do
    {:ok, console} = BeginnersWorkshops.workshop_console(workshop.id, clock: at(at))
    console.roster |> Map.values() |> List.flatten()
  end

  defp row(workshop, intake, at \\ @after_cutoff),
    do: workshop |> console_rows(at) |> Enum.find(&(&1.id == intake.id))

  # Two contacted people; the pass lapses both (seats were free).
  defp lapsed_fixture(coordinator) do
    {workshop, [{first, _}, {second, _}]} = contacted_fixture(coordinator, 2)
    assert {:ok, %{lapsed: 2}} = pass(workshop)
    {workshop, Repo.reload!(first), Repo.reload!(second)}
  end

  # One paid, one returned because the workshop was full; capacity 1.
  defp returned_fixture(coordinator) do
    {workshop, [{paid, paid_token}, {unpaid, _}]} = contacted_fixture(coordinator, 2)
    paid!(paid_token, paid, @now)
    capacity!(coordinator, workshop, 1)
    assert {:ok, %{returned: 1}} = pass(workshop)
    {workshop, Repo.reload!(paid), Repo.reload!(unpaid)}
  end

  defp new_intake!(%{id: id}), do: Repo.get!(Intake, id)

  describe "a lapsed person" do
    test "gets a new contacted Intake, is waiting again and is sent the Contact email",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      assert %WaitlistEntry{status: "removed"} = entry(lapsed)
      contact_template!(~w(windowEnd))

      assert {:ok, %{outcome: :done, state: "contacted"} = view} =
               re_offer(c, workshop, lapsed, %{"note" => "Called on 12 Nov"})

      assert %Intake{
               origin: "re_offer",
               batch_id: nil,
               state: "contacted",
               workshop_id: workshop_id,
               waitlist_id: waitlist_id,
               contacted_at: @after_cutoff,
               link_generation: 1
             } = new = new_intake!(view)

      assert workshop_id == workshop.id
      assert waitlist_id == lapsed.waitlist_id
      assert new.id != lapsed.id
      assert %Intake{state: "lapsed"} = Repo.reload!(lapsed)
      assert %WaitlistEntry{status: "waiting"} = entry(lapsed)

      # `{{windowEnd}}` is the workshop start: payment is open until then.
      assert [%{args: %{"data_variables" => %{"MESSAGE_HTML" => html}}}] = jobs_to(new)
      assert html == "<p>Saturday 14 November 2026, 18:30</p>"

      assert [%IntakeEmailLog{email_type: "contact_pay", occasion: "contact"}] =
               Repo.all(from(l in IntakeEmailLog, where: l.intake_id == ^new.id))

      assert [%IntakeEvent{command: "re_offer", note: "Called on 12 Nov", actor_principal_id: ^c}] =
               events(new)

      assert events(lapsed) == []

      # A repeat (a double click) finds the Re-offer made and does nothing.
      assert {:ok, %{outcome: :already_done}} = re_offer(c, workshop, lapsed)
      assert Repo.aggregate(from(i in Intake, where: i.workshop_id == ^workshop.id), :count) == 3
    end
  end

  describe "a returned person" do
    test "keeps their standing and priority, once staff have raised the capacity",
         %{coordinator: c} do
      {workshop, _paid, returned} = returned_fixture(c)
      before = entry(returned)
      assert before.status == "waiting"

      assert {:error, :no_free_place} = re_offer(c, workshop, returned)

      capacity!(c, workshop, 2, @after_cutoff)
      assert {:ok, %{outcome: :done} = view} = re_offer(c, workshop, returned)

      assert %Intake{origin: "re_offer", state: "contacted"} = new_intake!(view)
      assert %Intake{state: "returned"} = Repo.reload!(returned)
      after_re_offer = entry(returned)

      assert Map.take(after_re_offer, [:status, :initial_registration_date, :last_status_change]) ==
               Map.take(before, [:status, :initial_registration_date, :last_status_change])
    end
  end

  describe "refusals" do
    test "only a lapsed or returned Intake of this workshop", %{coordinator: c} do
      {workshop, [{contacted, _}, {declined, _}]} = contacted_fixture(c, 2)
      force_intake_state!(declined.id, "declined")

      assert {:error, :not_re_offerable} = re_offer(c, workshop, contacted)
      assert {:error, :not_re_offerable} = re_offer(c, workshop, declined)

      other = scheduled_fixture(c, %{"venue" => "Elsewhere Hall"})

      assert {:error, :intake_not_found} =
               BeginnersWorkshops.execute(
                 {:staff, c},
                 {:re_offer, other.id, contacted.id, %{}},
                 clock: at(@after_cutoff)
               )
    end

    test "once the workshop has started, been finalised or been cancelled", %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)

      assert {:error, :workshop_started} = re_offer(c, workshop, lapsed, %{}, @start)

      force_status!(workshop.id, "finalised")
      assert {:error, :after_finalisation} = re_offer(c, workshop, lapsed)

      force_status!(workshop.id, "cancelled")
      assert {:error, :already_cancelled} = re_offer(c, workshop, lapsed)
    end

    test "while the person has an open Intake in any workshop", %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      other = scheduled_fixture(c, %{"venue" => "Elsewhere Hall", "date" => "2026-12-12"})
      intake_fixture!(other.id, entry(lapsed), @cutoff)

      assert {:error, :open_intake} = re_offer(c, workshop, lapsed)
    end

    test "for someone removed too long ago, or with no profile to address", %{coordinator: c} do
      {workshop, lapsed, other} = lapsed_fixture(c)

      Repo.update_all(from(w in WaitlistEntry, where: w.id == ^lapsed.waitlist_id),
        set: [removed_at: ~U[2026-01-01 12:00:00Z]]
      )

      assert {:error, :not_eligible} = re_offer(c, workshop, lapsed)

      Repo.delete_all(from(p in UserProfile, where: p.waitlist_id == ^other.waitlist_id))
      assert {:error, :not_eligible} = re_offer(c, workshop, other)
    end

    test "for anyone without the Fast-track capability, assigned Staff included",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      coach = staff_fixture("coach")
      set_staff!(workshop.id, coach, [], actor: c)

      assert {:error, :forbidden} = re_offer(coach, workshop, lapsed)
      assert {:error, :forbidden} = re_offer(staff_fixture("member"), workshop, lapsed)
      assert {:ok, _} = re_offer(staff_fixture("president"), workshop, lapsed)
    end

    test "a note over 500 characters", %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)

      assert {:error, :invalid_note} =
               re_offer(c, workshop, lapsed, %{"note" => String.duplicate("a", 501)})
    end
  end

  describe "paying after the cutoff" do
    test "the re-offered person may start payment until the start; another contacted person may not",
         %{coordinator: c} do
      {workshop, [{first, _}, {_second, second_token}]} = contacted_fixture(c, 2)
      # The pass has not reached `second` yet; `first` lapsed.
      force_intake_state!(first.id, "lapsed")

      assert {:ok, view} = re_offer(c, workshop, first)
      new = new_intake!(view)

      assert {:ok, %{state: :pay, payment_cutoff: deadline}} =
               BeginnersWorkshops.intake_page(token(new), clock: at(@after_cutoff))

      assert DateTime.compare(deadline, @start) == :eq

      assert {:ok, %{state: :closed, closed_reason: :payment_closed}} =
               BeginnersWorkshops.intake_page(second_token, clock: at(@after_cutoff))

      Stripe.stub_create()
      assert {:error, :after_cutoff} = pay(second_token, @after_cutoff)
      assert {:error, :after_cutoff} = pay(token(new), @start)
      assert {:ok, %{checkout_url: _}} = pay(token(new), @after_cutoff)
    end

    test "a payment completed after the cutoff queues Pre-workshop info once",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      assert {:ok, view} = re_offer(c, workshop, lapsed)
      new = new_intake!(view)

      paid!(token(new), new, @after_cutoff)
      assert %Intake{state: "paid"} = Repo.reload!(new)
      assert {:ok, _} = pass(workshop, DateTime.add(@after_cutoff, 600))

      assert [%IntakeEmailLog{queued_at: @after_cutoff}] =
               Repo.all(
                 from(l in IntakeEmailLog,
                   where: l.intake_id == ^new.id and l.occasion == "pre_workshop"
                 )
               )
    end

    # The real race is `intake_payments_concurrency_test.exs`'s.
    test "the seat rule still holds: with one place left, the second re-offered payer is full",
         %{coordinator: c} do
      {workshop, [{first, _}, {second, _}]} = contacted_fixture(c, 2)
      force_intake_state!(first.id, "lapsed")
      force_intake_state!(second.id, "lapsed")
      assert {:ok, a} = re_offer(c, workshop, first)
      assert {:ok, b} = re_offer(c, workshop, second)
      capacity!(c, workshop, 1, @after_cutoff)

      Stripe.stub_create()
      assert {:ok, _} = pay(token(new_intake!(a)), @after_cutoff)
      assert {:error, :full} = pay(token(new_intake!(b)), @after_cutoff)
    end
  end

  describe "unpaid again" do
    test "the cutoff pass leaves the re-offered Intake open and the sweep does not visit it",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      assert {:ok, view} = re_offer(c, workshop, lapsed)

      refute workshop.id in BeginnersWorkshops.cutoff_owed_ids(@after_cutoff)

      assert {:ok, %{lapsed: 0, returned: 0}} = pass(workshop, @after_cutoff)
      assert %Intake{state: "contacted"} = new_intake!(view)
    end

    test "Attendance Finalisation lapses it with a seat free, with no email; the report counts both Intakes",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      assert {:ok, view} = re_offer(c, workshop, lapsed)
      emails_before = length(email_jobs())

      assert {:ok, _} =
               BeginnersWorkshops.execute(:system, {:finalise_attendance, workshop.id},
                 clock: at(@day_after)
               )

      assert %Intake{state: "lapsed"} = new_intake!(view)
      assert %WaitlistEntry{status: "removed"} = entry(lapsed)
      assert length(email_jobs()) == emails_before

      report = BeginnersWorkshops.report(clock: at(@day_after))
      outcome = Enum.find(report.outcomes, &(&1.workshop_id == workshop.id))
      assert outcome.contacted.total == 3
      assert outcome.exits_before_paying.lapsed == 3
    end

    test "Attendance Finalisation returns it when the workshop is full", %{coordinator: c} do
      {workshop, _paid, returned} = returned_fixture(c)
      capacity!(c, workshop, 2, @after_cutoff)
      assert {:ok, view} = re_offer(c, workshop, returned)
      capacity!(c, workshop, 1, @after_cutoff)

      assert {:ok, _} =
               BeginnersWorkshops.execute(:system, {:finalise_attendance, workshop.id},
                 clock: at(@day_after)
               )

      assert %Intake{state: "returned"} = new_intake!(view)
      assert %WaitlistEntry{status: "waiting"} = entry(returned)
    end
  end

  describe "a reschedule" do
    test "moving the cutoff past the Re-offer makes it ordinary: payable until the new cutoff, settled by its pass",
         %{coordinator: c} do
      {workshop, lapsed, _other} = lapsed_fixture(c)
      assert {:ok, view} = re_offer(c, workshop, lapsed)

      assert {:ok, _} =
               BeginnersWorkshops.execute(
                 {:staff, c},
                 {:reschedule_workshop, workshop.id,
                  %{"date" => "2026-12-05", "start_time" => "18:30", "end_time" => "20:30"}},
                 clock: at(@after_cutoff)
               )

      new_cutoff = ~U[2026-12-02 18:30:00.000000Z]
      new = new_intake!(view)

      assert {:ok, %{state: :pay, payment_cutoff: deadline}} =
               BeginnersWorkshops.intake_page(token(new), clock: at(@after_cutoff))

      assert DateTime.compare(deadline, new_cutoff) == :eq
      assert DateTime.compare(row(workshop, new).window_ends_at, new_cutoff) == :eq
      assert workshop.id in BeginnersWorkshops.cutoff_owed_ids(new_cutoff)

      assert {:ok, %{lapsed: 1}} = pass(workshop, new_cutoff)
      assert %Intake{state: "lapsed"} = Repo.reload!(new)
    end
  end

  describe "the console" do
    test "offers Re-offer on the lapsed row and then shows one row per person",
         %{coordinator: c} do
      {workshop, lapsed, other} = lapsed_fixture(c)

      assert :re_offer in row(workshop, lapsed).available_commands
      # Before the cutoff pass nobody has lapsed; after the start nobody may.
      refute :re_offer in row(workshop, lapsed, @start).available_commands

      assert {:ok, view} = re_offer(c, workshop, lapsed, %{"note" => "Rang the club"})

      rows = console_rows(workshop)
      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([view.id, other.id])

      row = Enum.find(rows, &(&1.id == view.id))
      assert row.state == "contacted"
      assert row.origin == "re_offer"
      assert DateTime.compare(row.window_ends_at, @start) == :eq
      assert [%{id: lapsed_id, state: "lapsed"}] = row.earlier_intakes
      assert lapsed_id == lapsed.id
      assert [%{command: "re_offer", note: "Rang the club"}] = row.history
      refute :re_offer in row.available_commands
    end
  end
end
