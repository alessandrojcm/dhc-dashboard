defmodule Dhc.Inventory.LoanRemindersTest do
  @moduledoc """
  ALE-287: the durable reminder ledger and its reconciliation.

  Proves the occurrences story 51 asks for — one pre-due, one at overdue,
  weekly thereafter, none for a closed loan — and the crash-safety the
  acceptance criteria demand: no duplicate unread notification per kind across
  retries and scheduler restarts, and a missed tick repaired by the next pass
  rather than lost.

  Loans reach their positions through the real member and operator commands, so
  the ledger is proven against what the lifecycle actually writes. Direct SQL
  appears only to age an already checked-out loan past its due date, which no
  public command may do (`check_out_loan/3` is gated to the approved window and
  `edit_loan_dates/3` refuses a due date before the handover), and to simulate
  a crash between the ledger claim and the notification.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.LoanReminders
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  # ── Occurrences (story 51) ──────────────────────────────────────

  describe "the pre-due reminder" do
    test "is due the day before the approved due date and notifies the borrower" do
      today = ClubCalendar.today()
      %{loan: loan, borrower: borrower} = checked_out(due_on: Date.add(today, 1))

      assert %{delivered: 1} = LoanReminders.run()

      assert [%Notification{principal_id: ^borrower} = notification] = notifications()
      assert notification.body =~ "due"
      assert kinds(loan) == ["pre_due"]
    end

    test "is not due two days before the due date" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: Date.add(today, 2))

      assert %{delivered: 0} = LoanReminders.run()

      assert notifications() == []
      assert kinds(loan) == []
    end

    test "is not sent for a loan due today, which the overdue reminder owns" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: today)

      # Due today is not late and no longer "due tomorrow": the next reminder
      # this loan earns is the overdue one.
      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == []
    end
  end

  describe "the overdue reminder" do
    test "is sent once the due date has passed" do
      %{loan: loan, borrower: borrower} = overdue_loan(days_late: 1)

      assert %{delivered: 1} = LoanReminders.run()

      assert [%Notification{principal_id: ^borrower} = notification] = notifications()
      assert notification.body =~ "overdue"
      assert kinds(loan) == ["overdue"]
    end

    test "does not repeat daily while the loan stays overdue" do
      today = ClubCalendar.today()
      %{loan: loan} = overdue_loan(days_late: 1)
      assert %{delivered: 1} = LoanReminders.run()

      # Day two and three are still the same overdue occurrence: the escalation
      # after it is weekly, not daily (story 51). Time advances here rather than
      # the due date moving — moving the due date is an *edit*, which earns its
      # own reminders by design.
      assert %{delivered: 0} = LoanReminders.run(Date.add(today, 1))
      assert %{delivered: 0} = LoanReminders.run(Date.add(today, 2))

      assert kinds(loan) == ["overdue"]
    end
  end

  describe "the weekly escalation" do
    test "sends one reminder a week after the last one, then one a week after that" do
      %{loan: loan} = overdue_loan(days_late: 1)
      assert %{delivered: 1} = LoanReminders.run()

      # Time passes by ageing the deliveries rather than by moving `today`: the
      # pacing is measured from when the member was last actually reminded, so
      # the ledger's own timestamps are what has to move.
      age_deliveries(loan, 7)
      assert %{delivered: 1} = LoanReminders.run()
      assert kinds(loan) == ["overdue", "overdue_week_1"]

      # Mid-week is not a new occurrence.
      age_deliveries(loan, 3)
      assert %{delivered: 0} = LoanReminders.run()

      age_deliveries(loan, 4)
      assert %{delivered: 1} = LoanReminders.run()
      assert kinds(loan) == ["overdue", "overdue_week_1", "overdue_week_2"]
    end

    test "continues indefinitely while the item is out, one reminder per week" do
      %{loan: loan} = overdue_loan(days_late: 1)
      assert %{delivered: 1} = LoanReminders.run()

      for _week <- 1..6 do
        age_deliveries(loan, 7)
        assert %{delivered: 1} = LoanReminders.run()
      end

      # "then weekly until return" (story 51) has no ceiling, and no week is
      # skipped or repeated.
      assert kinds(loan) == ["overdue"] ++ Enum.map(1..6, &"overdue_week_#{&1}")
    end
  end

  # ── Immediate overdue (ALE-287: "immediate-overdue handling") ───

  describe "a loan already overdue when it is first seen" do
    test "is told it is overdue, not dropped into mid-escalation" do
      %{loan: loan} = overdue_loan(days_late: 30)

      assert %{delivered: 1} = LoanReminders.run()

      # A month-late loan has never been told anything. Its first message must
      # be the overdue one: opening at `overdue_week_4` would reference an
      # escalation that never happened.
      assert kinds(loan) == ["overdue"]
      assert [%Notification{body: body}] = notifications()
      assert body =~ "overdue"
    end

    test "a scheduler down for a month delivers one reminder, not a month of backlog" do
      %{loan: loan} = overdue_loan(days_late: 30)

      assert %{delivered: 1} = LoanReminders.run()

      # Repair does not mean replay: the missed weeks are not owed all at once,
      # and a second pass the same day adds nothing.
      assert %{delivered: 0} = LoanReminders.run()
      assert [_one] = notifications()

      # From there the escalation paces weekly from the delivery, not from the
      # long-past due date.
      age_deliveries(loan, 6)
      assert %{delivered: 0} = LoanReminders.run()

      age_deliveries(loan, 1)
      assert %{delivered: 1} = LoanReminders.run()
      assert kinds(loan) == ["overdue", "overdue_week_1"]
    end

    test "never claims an elapsed week the calendar does not support" do
      %{loan: loan} = overdue_loan(days_late: 30)

      assert %{delivered: 1} = LoanReminders.run()
      age_deliveries(loan, 7)
      assert %{delivered: 1} = LoanReminders.run()

      # The follow-up counts reminders, not weeks, so no message may say "a
      # week after its due date" about a loan a month late.
      for %Notification{body: body} <- notifications() do
        refute body =~ "week"
      end
    end

    test "a missed pre-due day is not backfilled once the loan is late" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: Date.add(today, 1))

      # The pass never ran on the pre-due day. Telling the member their loan is
      # "due back tomorrow" when it is already late would be false, so the
      # overdue reminder supersedes it rather than both being delivered.
      assert %{delivered: 1} = LoanReminders.run(Date.add(today, 2))
      assert kinds(loan) == ["overdue"]
    end
  end

  # ── Closed loans earn nothing (story 51) ────────────────────────

  describe "closed loans" do
    test "a returned loan gets no reminder however late it was" do
      %{loan: loan} = overdue_loan(days_late: 5)
      assert {:ok, _} = Inventory.return_loan(loan, operator())

      assert %{delivered: 0} = LoanReminders.run()
      assert notifications() == []
      assert kinds(loan) == []
    end

    test "a cancelled approved loan gets no reminder" do
      today = ClubCalendar.today()
      %{loan: loan} = approved(due_on: Date.add(today, 1))
      assert {:ok, _} = Inventory.cancel_operator_loan(loan, %{}, operator())

      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == []
    end

    test "a rejected request gets no reminder" do
      %{loan: loan} = requested()
      assert {:ok, _} = Inventory.reject_loan(loan, %{}, operator())

      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == []
    end

    test "a pending request gets no reminder: nothing has been lent yet" do
      %{loan: loan} = requested()

      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == []
    end

    test "a claim left behind for a loan that has since closed is released, not delivered" do
      %{loan: loan} = overdue_loan(days_late: 1)

      # The state a crashed pass leaves when the loan closes in the same window:
      # a claim with no delivery, for a loan nobody should chase any more. It is
      # also the durable evidence of the read-then-deliver race, since `run/1`
      # selects live loans and a return can commit before the notification.
      assert %{delivered: 1} = LoanReminders.run()
      undeliver(loan)
      assert {:ok, _} = Inventory.return_loan(loan, operator())

      assert %{delivered: 0} = LoanReminders.run()

      # No reminder for a returned item (story 51), and the stale claim is
      # cleaned up rather than reported as repair work forever.
      assert [_from_before_the_return] = notifications()
      assert %{pending: 0} = LoanReminders.due()
    end

    test "returning a loan stops the weekly escalation" do
      today = ClubCalendar.today()
      %{loan: loan} = overdue_loan(days_late: 1)
      assert %{delivered: 1} = LoanReminders.run()

      assert {:ok, _} = Inventory.return_loan(loan, operator())

      # A week later the loan would have earned its weekly escalation had it
      # still been out. Closed is closed, with no escalation state to unwind.
      assert %{delivered: 0} = LoanReminders.run(Date.add(today, 6))
      assert kinds(loan) == ["overdue"]
    end
  end

  # ── An approved-but-not-collected loan ──────────────────────────

  describe "an approved loan that was never handed over" do
    test "is reminded, because the member still holds a live commitment" do
      today = ClubCalendar.today()
      %{loan: loan} = approved(due_on: Date.add(today, 1))

      assert %{delivered: 1} = LoanReminders.run()
      assert kinds(loan) == ["pre_due"]
    end
  end

  # ── Due-date edits (acceptance criterion 2) ─────────────────────

  describe "a due-date edit" do
    test "reschedules the pre-due reminder onto the new date" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: Date.add(today, 1))

      assert %{delivered: 1} = LoanReminders.run()
      assert kinds(loan) == ["pre_due"]

      # Pushing the due date out means the member is no longer due tomorrow, so
      # nothing is owed until the new date approaches.
      assert {:ok, _} = edit_due(loan, Date.add(today, 10))
      assert %{delivered: 0} = LoanReminders.run()

      # The day before the *new* date earns a second pre-due reminder: the
      # revision, not the kind, is what makes it a new occurrence.
      assert %{delivered: 1} = LoanReminders.run(Date.add(today, 9))

      assert [%Notification{}, %Notification{}] = notifications()
      assert kinds(loan) == ["pre_due", "pre_due"]
    end

    test "moving a due date away and back does not re-notify for the same date" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: Date.add(today, 1))

      assert %{delivered: 1} = LoanReminders.run()

      assert {:ok, _} = edit_due(loan, Date.add(today, 10))
      assert {:ok, _} = edit_due(loan, Date.add(today, 1))

      # The revision is derived from the due date, not a counter that an edit
      # bumps, so a date the member has already been reminded about stays
      # reminded however many times it is edited away and back.
      assert %{delivered: 0} = LoanReminders.run()
      assert [_only_one] = notifications()
      assert kinds(loan) == ["pre_due"]
    end

    test "extending an overdue loan cancels its overdue reminder" do
      today = ClubCalendar.today()
      %{loan: loan} = overdue_loan(days_late: 1)

      assert %{delivered: 1} = LoanReminders.run()

      # Overdue is derived, so extending the date makes the loan on time again
      # with nothing to undo — and no further reminder until the new date.
      assert {:ok, _} = edit_due(loan, Date.add(today, 30))

      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == ["overdue"]
    end

    test "restating the same due date is not a new occurrence" do
      today = ClubCalendar.today()
      %{loan: loan} = checked_out(due_on: Date.add(today, 1))

      assert %{delivered: 1} = LoanReminders.run()
      assert {:ok, _} = edit_due(loan, Date.add(today, 1))

      # The revision is derived from the due date itself, so an edit that
      # changes nothing cannot manufacture a duplicate reminder.
      assert %{delivered: 0} = LoanReminders.run()
      assert kinds(loan) == ["pre_due"]
    end
  end

  # ── Idempotency across retries and restarts (AC 1) ──────────────

  describe "repeated passes" do
    test "a second pass in the same state delivers nothing new" do
      %{loan: loan} = overdue_loan(days_late: 1)

      assert %{delivered: 1} = LoanReminders.run()
      assert %{delivered: 0} = LoanReminders.run()
      assert %{delivered: 0} = LoanReminders.run()

      assert [_only_one] = notifications()
      assert kinds(loan) == ["overdue"]
    end

    test "a crash between the ledger claim and the notification is repaired, not duplicated" do
      %{loan: loan} = overdue_loan(days_late: 1)

      assert %{delivered: 1} = LoanReminders.run()
      assert [%Notification{id: original_id}] = notifications()

      # Simulate the crash window: the ledger row was claimed but delivery
      # never completed. The next pass must retry it.
      undeliver(loan)
      assert %{delivered: 1} = LoanReminders.run()

      # Retried, yet the member still has exactly one unread overdue
      # notification — the keyed seam absorbs the repeat (AC 1).
      assert [%Notification{id: ^original_id}] = notifications()
      assert kinds(loan) == ["overdue"]
    end

    test "an unclaimed ledger row left by a crash before delivery is picked up" do
      %{loan: loan} = overdue_loan(days_late: 1)

      # A pass that claimed the row and died before notifying leaves an
      # undelivered row; reconciliation is the same code path as normal
      # delivery, so the repair needs no separate mechanism.
      assert %{delivered: 1} = LoanReminders.run()
      undeliver(loan)

      assert %{owed: 1, pending: 1} = LoanReminders.due()
      assert %{delivered: 1} = LoanReminders.run()
      assert %{owed: 0, pending: 0} = LoanReminders.due()
    end

    test "the member reading a reminder does not earn them a duplicate" do
      %{loan: loan, borrower: borrower} = overdue_loan(days_late: 1)
      assert %{delivered: 1} = LoanReminders.run()

      [%Notification{id: id}] = notifications()
      assert {:ok, _} = Dhc.Notifications.mark_read(borrower, id)

      # The ledger, not the unread state, is what records that this occurrence
      # was delivered — so a read notification is never re-sent.
      assert %{delivered: 0} = LoanReminders.run()
      assert [_only_one] = notifications()
      assert kinds(loan) == ["overdue"]
    end
  end

  # ── Many loans in one pass ──────────────────────────────────────

  describe "a pass over several loans" do
    test "delivers each loan's own occurrence and reports the total" do
      today = ClubCalendar.today()
      %{loan: pre_due} = checked_out(due_on: Date.add(today, 1))
      %{loan: late} = overdue_loan(days_late: 1)
      %{loan: very_late} = overdue_loan(days_late: 14)
      %{loan: quiet} = checked_out(due_on: Date.add(today, 5))

      assert %{delivered: 3} = LoanReminders.run()

      assert kinds(pre_due) == ["pre_due"]
      assert kinds(late) == ["overdue"]
      # However late, a loan's first contact is the overdue reminder.
      assert kinds(very_late) == ["overdue"]
      assert kinds(quiet) == []
    end

    test "one loan's failure does not stop the others" do
      today = ClubCalendar.today()
      %{loan: first} = checked_out(due_on: Date.add(today, 1))
      %{loan: second} = overdue_loan(days_late: 1)

      # A reminder whose recipient no longer resolves cannot be delivered; the
      # pass must still deliver every other loan rather than aborting the tick.
      orphan_borrower(first)

      assert %{delivered: 1, failed: 1} = LoanReminders.run()
      assert kinds(second) == ["overdue"]
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp notifications, do: Repo.all(from n in Notification, order_by: n.created_at)

  defp kinds(loan_id) do
    Repo.all(
      from r in "inventory_loan_reminders",
        where: r.loan_id == type(^loan_id, :binary_id) and not is_nil(r.delivered_at),
        order_by: r.kind,
        select: r.kind
    )
  end

  # ── Lifecycle fixtures ──────────────────────────────────────────

  defp requested(opts \\ []) do
    today = ClubCalendar.today()
    due_on = Keyword.get(opts, :due_on, Date.add(today, 7))
    item = item()
    borrower = principal()

    {:ok, loan} =
      Inventory.request_loan(
        item.slug,
        %{"startsOn" => Date.to_iso8601(today), "dueOn" => Date.to_iso8601(due_on)},
        borrower
      )

    %{loan: loan.id, borrower: borrower, item: item}
  end

  defp approved(opts) do
    %{loan: loan} = fixture = requested(opts)
    assert {:ok, _} = Inventory.approve_loan(loan, %{}, operator())
    fixture
  end

  defp checked_out(opts) do
    %{loan: loan} = fixture = approved(opts)
    assert {:ok, _} = Inventory.check_out_loan(loan, %{}, operator())
    fixture
  end

  defp overdue_loan(opts) do
    days_late = Keyword.fetch!(opts, :days_late)
    today = ClubCalendar.today()
    fixture = checked_out(due_on: today)
    age_due_date(fixture.loan, days_late: days_late)
    fixture
  end

  defp edit_due(loan, due_on),
    do: Inventory.edit_loan_dates(loan, %{"dueOn" => Date.to_iso8601(due_on)}, operator())

  # Ages an already checked-out loan past its due date. The one state no public
  # command can reach: checkout is gated to the approved window and a due-date
  # edit may not precede the handover, so real overdue only comes from the
  # passage of time.
  defp age_due_date(loan, days_late: days_late) do
    today = ClubCalendar.today()

    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [Date.add(today, -days_late - 7), Date.add(today, -days_late), Ecto.UUID.dump!(loan)]
    )
  end

  # Moves a loan's delivered reminders `days` further into the past, which is
  # how the passage of time is simulated for the weekly escalation: the pacing
  # is measured from the last delivery, so ageing the ledger is what makes
  # "a week later" true. Moving `today` instead would leave the stamps at the
  # real clock and desynchronize the two.
  defp age_deliveries(loan, days) do
    Repo.query!(
      "UPDATE inventory_loan_reminders SET delivered_at = delivered_at - ($1 || ' days')::interval WHERE loan_id = $2 AND delivered_at IS NOT NULL",
      [to_string(days), Ecto.UUID.dump!(loan)]
    )
  end

  # Reopens the crash window: the ledger claim survives but delivery does not.
  defp undeliver(loan) do
    Repo.query!(
      "UPDATE inventory_loan_reminders SET delivered_at = NULL WHERE loan_id = $1",
      [Ecto.UUID.dump!(loan)]
    )
  end

  # Points the loan at a borrower that is not a principal, so its reminder
  # cannot be created while every other loan's still can.
  defp orphan_borrower(loan) do
    Repo.query!(
      "ALTER TABLE inventory_loans DROP CONSTRAINT IF EXISTS inventory_loans_borrower_principal_id_fkey",
      []
    )

    Repo.query!(
      "UPDATE inventory_loans SET borrower_principal_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(loan)]
    )
  end

  # ── Base fixtures ───────────────────────────────────────────────

  defp item do
    {:ok, category} =
      Inventory.create_category(%{"name" => "Reminder cat #{unique()}"})

    {:ok, container} =
      Inventory.create_container(%{"name" => "Reminder box #{unique()}"}, operator())

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => container.id, "category_id" => category.id},
        operator()
      )

    item
  end

  defp operator, do: principal()

  defp principal do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "reminder-#{unique()}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp unique, do: System.unique_integer([:positive])
end
