defmodule Dhc.Inventory.LoanReminders do
  @moduledoc """
  ALE-287: loan reminders as a durable ledger with self-repairing delivery.

  Story 51 asks for one reminder the day before a loan is due, one when it
  becomes overdue, then one a week for as long as the item is out, with no
  duplicates and none for a closed loan. The hard part is not the schedule but
  the crash safety: the acceptance criteria require no duplicate unread
  notification per kind *across retries and scheduler restarts*, and that a
  missed event be repaired rather than lost.

  ## The ledger is the schedule

  There is no per-reminder scheduled job. A single pass (`run/0`, driven by
  `Dhc.Inventory.Workers.LoanReminderWorker`) asks every live loan what it is
  owed next, and the ledger records what has already been delivered. Normal
  delivery and reconciliation are therefore the same code path: a tick that
  never ran, a job that crashed, and a node that was down for a week all leave
  the same evidence — an occurrence with no delivered ledger row — and the next
  pass repairs it. There is no second mechanism able to disagree with the first,
  and nothing to backfill after a deploy.

  ## Occurrences follow the loan's own history, not the calendar alone

  `owed_occurrence/3` maps a due date, today, and what the loan has *already
  been sent* onto at most one owed occurrence:

    * `pre_due` — the club-calendar day before the due date. Time-windowed: if
      the day passes undelivered it is not backfilled, because the overdue
      reminder supersedes it and telling someone their loan is "due tomorrow"
      after it is already late would be false.
    * `overdue` — the **first** overdue contact, whenever it happens. A loan
      discovered a month late still gets this one first, which is what makes
      immediate-overdue handling correct: a loan approved with a due date
      already past has never been told it is late, so its first message must
      say so rather than open mid-escalation.
    * `overdue_week_<n>` — the *n*-th weekly follow-up, paced a week apart from
      the previous delivery.

  Pacing from the previous *delivery* rather than from the due date is what
  keeps reconciliation from becoming a flood. A calendar-derived week number
  would consider weeks 1..4 of a month-late loan all owed at once and empty
  them into the member's inbox in consecutive passes. Here the loan is reminded
  immediately, then once a week — repair without a backlog dump. The week
  number counts follow-ups, so the *body* states the real lateness from the due
  date and never claims a week that has not passed.

  ## Exactly-once, out of two at-least-once steps

  Delivery is claim → notify → stamp:

    1. **Claim.** Insert the ledger row `ON CONFLICT DO NOTHING` on
       `inventory_loan_reminders_ledger_key_unique`. A concurrent pass — two
       nodes, an Oban retry, an overlapping tick — loses the insert and skips
       the reminder, so the claim, not a lock, is what serializes delivery.
    2. **Notify.** Call `Dhc.Notifications.create_keyed/3` with the ledger key
       as the notification key. Idempotent in its own right, so a crash between
       the claim and the stamp cannot produce a second notification when the
       row is retried.
    3. **Stamp.** Set `delivered_at`. An unstamped claim is a reminder awaiting
       repair; the next pass retries it and the keyed seam absorbs the repeat.

  Neither step is exactly-once alone. The pair is, because the ledger key and
  the notification key are the *same* identity — the ledger cannot record a
  delivery the notification seam would treat as new.

  ## A due-date edit costs the transition path nothing

  `due_on_revision` is **derived** from `approved_due_on`
  (`Date.to_gregorian_days/1`), not incremented by whoever moved the date. So
  editing a due date automatically invalidates every reminder key for the old
  date and earns the new date its own occurrences, while
  `Dhc.Inventory.OperatorLoans.edit_loan_dates/3` writes nothing here and knows
  nothing about reminders. That is why ALE-296 could stay reminder-free and
  still satisfy "due-date edits reschedule correctly": rescheduling is a
  consequence of the key, not an action anyone has to remember to take.

  It also means a restated date is not a new occurrence — the revision is the
  date, so an edit that changes nothing changes no key.

  ## Closed loans earn nothing

  Only `approved` and `checked_out` loans are considered, and the loan's status
  is re-read under the claim before the notification is created: a return that
  commits between the pass's read and its delivery must not still produce a
  reminder. A returned, cancelled, or rejected loan then drops out with no
  escalation state to unwind — the same "derived, never stored" rule overdue
  itself follows. A pending request has lent nothing and is never reminded.

  ## Recipients

  The borrower, who is the one who has to act. Operator-facing overdue
  notification (story 50) belongs to the exposure ticket that also wires
  transition notifications (ALE-286c) and would be added here as a second
  recipient per occurrence — the ledger is already keyed by
  `recipient_principal_id` for exactly that, so it needs no reshaping.
  """

  import Ecto.Query

  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanReminder
  alias Dhc.Notifications
  alias Dhc.Repo

  require Logger

  # Statuses with a live commitment to remind about. An `approved` loan counts
  # even before handover: the member has a reservation with a date attached.
  @live_statuses ~w(approved checked_out)

  # The gap between weekly follow-ups, in club-calendar days.
  @escalation_days 7

  @typedoc "What one pass did. `failed` counts reminders owed but not delivered."
  @type pass :: %{
          delivered: non_neg_integer(),
          failed: non_neg_integer(),
          considered: non_neg_integer()
        }

  @typedoc """
  What a loan has already been sent for its current due-date revision.

  `last_delivered_on` is the club-calendar day of the most recent delivery,
  which is what paces the weekly follow-ups.
  """
  @type history :: %{kinds: MapSet.t(String.t()), last_delivered_on: Date.t() | nil}

  @doc """
  Deliver every reminder currently owed, repairing anything a previous pass
  missed.

  Safe to call at any frequency and from several nodes at once: the ledger
  claim decides who delivers, and re-running in an unchanged state delivers
  nothing. Never raises for one bad loan — a failure is counted and logged so a
  single undeliverable reminder cannot stop the tick for every other loan.
  """
  @spec run() :: pass()
  def run, do: run(ClubCalendar.today())

  @doc """
  The same pass, as of an explicit club-calendar day.

  `today` is a parameter for the same reason
  `Dhc.Inventory.OperatorLoans.operator_view/2` takes one: the schedule is a
  function of a loan's due date and one calendar day, and a pass that read the
  clock per loan could straddle midnight mid-list. It also lets the rules be
  exercised across weeks of a loan's life without rewriting its due date, which
  would be a due-date *edit* rather than the passage of time.
  """
  @spec run(Date.t()) :: pass()
  def run(%Date{} = today) do
    release_closed_claims()
    owed = owed_reminders(today)

    {delivered, failed} =
      Enum.reduce(owed, {0, 0}, fn reminder, {delivered, failed} ->
        case deliver(reminder) do
          :delivered -> {delivered + 1, failed}
          :skipped -> {delivered, failed}
          {:error, _reason} -> {delivered, failed + 1}
        end
      end)

    %{delivered: delivered, failed: failed, considered: length(owed)}
  end

  @doc """
  What `run/0` would attempt right now, without delivering anything.

  `pending` counts claimed-but-undelivered ledger rows — the evidence a
  previous pass crashed mid-delivery — so an operator or a test can see repair
  work outstanding.
  """
  @spec due() :: %{owed: non_neg_integer(), pending: non_neg_integer()}
  def due, do: due(ClubCalendar.today())

  @doc "The same read, as of an explicit club-calendar day."
  @spec due(Date.t()) :: %{owed: non_neg_integer(), pending: non_neg_integer()}
  def due(%Date{} = today) do
    pending =
      Repo.aggregate(from(r in LoanReminder, where: is_nil(r.delivered_at)), :count, :id)

    %{owed: length(owed_reminders(today)), pending: pending}
  end

  @doc """
  The single occurrence a loan owes, given its due date, today, and what it has
  already been sent.

  Public because it *is* the schedule: the reminder rules are one function of a
  due date, a calendar day, and the loan's own delivery history, with no hidden
  state, so they can be reasoned about and tested directly.
  """
  @spec owed_occurrence(Date.t() | nil, Date.t(), history()) :: String.t() | nil
  def owed_occurrence(nil, _today, _history), do: nil

  def owed_occurrence(%Date{} = due_on, %Date{} = today, history) do
    days_late = Date.diff(today, due_on)

    cond do
      # The pre-due day, and only that day: a missed pre-due reminder is not
      # backfilled, because "due tomorrow" is false once the loan is late.
      days_late == -1 -> unless sent?(history, "pre_due"), do: "pre_due"
      # Before the pre-due day, and the due day itself — not late yet, and the
      # overdue reminder owns the day after.
      days_late <= 0 -> nil
      # First overdue contact, however late the loan is discovered.
      not sent?(history, "overdue") -> "overdue"
      true -> next_follow_up(history, today)
    end
  end

  # Weekly follow-ups are paced from the previous *delivery*, not from the due
  # date: a loan discovered a month late has already been told it is overdue,
  # and deriving the week from the calendar would make weeks 1..4 all owed at
  # once and empty them into the inbox in consecutive passes.
  defp next_follow_up(%{last_delivered_on: nil}, _today), do: nil

  defp next_follow_up(%{last_delivered_on: %Date{} = last} = history, today) do
    if Date.diff(today, last) >= @escalation_days,
      do: "overdue_week_#{follow_ups_sent(history) + 1}"
  end

  defp sent?(%{kinds: kinds}, kind), do: MapSet.member?(kinds, kind)

  defp follow_ups_sent(%{kinds: kinds}) do
    kinds
    |> Enum.map(&follow_up_number/1)
    |> Enum.max(fn -> 0 end)
  end

  defp follow_up_number("overdue_week_" <> number) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _unparsable -> 0
    end
  end

  defp follow_up_number(_kind), do: 0

  # ── Owed reminders ──────────────────────────────────────────────

  # Two queries for the whole pass — the live loans, then their delivered
  # ledger rows — and the schedule applied in memory. The rules are calendar
  # arithmetic over a set bounded by the items physically out on loan, so
  # expressing them in SQL would buy nothing and split them across two
  # languages; asking the ledger per loan would make the pass N+1.
  defp owed_reminders(today) do
    loans = live_loans()
    histories = histories(loans)

    Enum.flat_map(loans, fn loan ->
      history =
        Map.get(histories, {loan.loan_id, revision(loan.approved_due_on)}, empty_history())

      case owed_occurrence(loan.approved_due_on, today, history) do
        nil -> []
        kind -> [Map.put(loan, :kind, kind)]
      end
    end)
  end

  defp live_loans do
    Repo.all(
      from l in Loan,
        where: l.status in ^@live_statuses,
        where: not is_nil(l.approved_due_on),
        select: %{
          loan_id: l.id,
          borrower_principal_id: l.borrower_principal_id,
          approved_due_on: l.approved_due_on,
          item_label: l.item_label_snapshot
        }
    )
  end

  # Delivery days are converted in Postgres, for the reason `ClubCalendar`
  # exists: the application ships no time-zone database, and a UTC timestamp
  # late in the evening is already the next Dublin day in summer.
  defp histories([]), do: %{}

  defp histories(loans) do
    loan_ids = Enum.map(loans, & &1.loan_id)
    zone = ClubCalendar.zone()

    from(r in LoanReminder,
      where: r.loan_id in ^loan_ids,
      where: not is_nil(r.delivered_at),
      select: %{
        loan_id: r.loan_id,
        revision: r.due_on_revision,
        kind: r.kind,
        delivered_on: fragment("(? AT TIME ZONE ?)::date", r.delivered_at, ^zone)
      }
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.loan_id, &1.revision})
    |> Map.new(fn {key, rows} -> {key, history(rows)} end)
  end

  defp history(rows) do
    %{
      kinds: MapSet.new(rows, & &1.kind),
      last_delivered_on: rows |> Enum.map(& &1.delivered_on) |> Enum.max(Date)
    }
  end

  defp empty_history, do: %{kinds: MapSet.new(), last_delivered_on: nil}

  # ── Delivery ────────────────────────────────────────────────────

  defp deliver(reminder) do
    case claim(reminder) do
      {:ok, id} ->
        notify_and_stamp(reminder, id)

      :already_delivered ->
        :skipped

      {:error, reason} ->
        Logger.error(
          "[loan-reminders] Could not claim loan #{reminder.loan_id} kind #{reminder.kind}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The claim is the serialization point. `DO NOTHING` means a concurrent pass
  # already owns this occurrence, so this one steps aside rather than competing
  # for a lock — and an *undelivered* row from a crashed pass is reclaimed by
  # its id so the repair goes down the same path as a first delivery.
  defp claim(reminder) do
    revision = revision(reminder.approved_due_on)
    now = DateTime.utc_now()

    entry = %{
      loan_id: reminder.loan_id,
      recipient_principal_id: reminder.borrower_principal_id,
      kind: reminder.kind,
      due_on_revision: revision,
      scheduled_for: now,
      created_at: now,
      updated_at: now
    }

    case insert_claim(entry) do
      {1, [%LoanReminder{id: id}]} ->
        {:ok, id}

      {0, _none} ->
        # The row exists. Undelivered means a previous pass died between claim
        # and delivery: retry it here rather than waiting for a separate
        # reconciliation mechanism.
        reclaim_undelivered(reminder, revision)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ledger's foreign keys (`loan_id`, `recipient_principal_id`) are a
  # backstop against writing a reminder for a row that does not exist, and a
  # pass walks *every* live loan: letting one unwritable claim raise would abort
  # the tick for every healthy loan behind it. Translated to a counted failure
  # instead, matching how the loan commands translate their own constraints
  # rather than surfacing a `Postgrex.Error`.
  defp insert_claim(entry) do
    Repo.insert_all(LoanReminder, [entry],
      on_conflict: :nothing,
      conflict_target: [:loan_id, :recipient_principal_id, :kind, :due_on_revision],
      returning: [:id]
    )
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] -> {:error, error}
  end

  defp reclaim_undelivered(reminder, revision) do
    Repo.one(
      from r in LoanReminder,
        where:
          r.loan_id == ^reminder.loan_id and
            r.recipient_principal_id == ^reminder.borrower_principal_id and
            r.kind == ^reminder.kind and
            r.due_on_revision == ^revision and
            is_nil(r.delivered_at),
        select: r.id
    )
    |> case do
      nil -> :already_delivered
      id -> {:ok, id}
    end
  end

  # `create_keyed/3` is idempotent on the same key, so a reminder retried after
  # a crash resolves to the notification that already exists instead of a
  # second unread row (AC 1). The stamp lands only after the notification is
  # durable, so the ledger can never claim a delivery that did not happen.
  defp notify_and_stamp(reminder, ledger_id) do
    if live?(reminder.loan_id) do
      case Notifications.create_keyed(
             reminder.borrower_principal_id,
             notification_key(reminder),
             body(reminder)
           ) do
        {:ok, _created_or_already} ->
          stamp(ledger_id)
          :delivered

        {:error, reason} ->
          # The claim stays, unstamped, so the next pass retries it. Losing the
          # tick for every other loan because one recipient no longer resolves
          # would be worse than a delayed reminder.
          Logger.error(
            "[loan-reminders] Delivery failed for loan #{reminder.loan_id} kind #{reminder.kind}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      # The loan closed between this pass's read and its delivery. A returned
      # item must not still be chased (story 51), so the claim is released
      # rather than stamped — a closed loan is never reconsidered, and leaving
      # it would report phantom repair work forever.
      release(ledger_id)
      :skipped
    end
  end

  defp live?(loan_id) do
    Repo.exists?(from l in Loan, where: l.id == ^loan_id and l.status in ^@live_statuses)
  end

  defp stamp(ledger_id) do
    now = DateTime.utc_now()

    from(r in LoanReminder, where: r.id == ^ledger_id and is_nil(r.delivered_at))
    |> Repo.update_all(set: [delivered_at: now, updated_at: now])

    :ok
  end

  defp release(ledger_id) do
    Repo.delete_all(from r in LoanReminder, where: r.id == ^ledger_id and is_nil(r.delivered_at))
    :ok
  end

  # An undelivered claim whose loan has since closed is work nobody should ever
  # do: the item is back, so the reminder must not be delivered, and leaving the
  # claim would report repair work that never completes. Delivered rows are
  # never touched — they are the record of what the member was actually told.
  defp release_closed_claims do
    Repo.delete_all(
      from r in LoanReminder,
        as: :reminder,
        where: is_nil(r.delivered_at),
        where:
          not exists(
            from l in Loan,
              where: l.id == parent_as(:reminder).loan_id and l.status in ^@live_statuses,
              select: 1
          )
    )

    :ok
  end

  # ── Keys ────────────────────────────────────────────────────────

  # The notification key mirrors the ledger key exactly, minus the recipient
  # (which `create_keyed/3` scopes on its own). Sharing one identity is what
  # makes the two at-least-once steps add up to exactly-once delivery.
  defp notification_key(reminder) do
    "inventory:loan:#{reminder.loan_id}:reminder:#{reminder.kind}:r#{revision(reminder.approved_due_on)}"
  end

  # Derived, never incremented: the due date *is* the revision. A due-date edit
  # invalidates the old keys for free, and restating the same date changes
  # nothing, so no transition has to write a reminder row.
  defp revision(%Date{} = due_on), do: Date.to_gregorian_days(due_on)

  # ── Bodies ──────────────────────────────────────────────────────

  # Deliberately plain and non-personal: notifications carry no operator notes
  # and no borrower identity (the recipient is the borrower), matching the
  # member-facing privacy rule (story 45).
  defp body(%{kind: "pre_due"} = reminder),
    do: "#{label(reminder)} is due back tomorrow (#{date(reminder)})."

  defp body(%{kind: "overdue"} = reminder),
    do: "#{label(reminder)} is overdue — it was due back on #{date(reminder)}."

  # The follow-up number counts reminders, not weeks, so lateness is stated
  # from the due date itself. A message must never claim an elapsed week the
  # calendar does not support — which it would if a loan reminded late reused a
  # calendar-derived week number.
  defp body(%{kind: "overdue_week_" <> _number} = reminder),
    do: "#{label(reminder)} is still overdue — it was due back on #{date(reminder)}."

  defp label(%{item_label: label}) when is_binary(label) and label != "", do: label
  defp label(_reminder), do: "A borrowed item"

  defp date(%{approved_due_on: due_on}), do: Date.to_iso8601(due_on)
end
