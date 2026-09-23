defmodule Dhc.Inventory.LoanPolicy do
  @moduledoc """
  GH-508: the pure loan-date and readiness predicates shared by authoritative
  commands and advisory reads.

  `Dhc.Inventory.AvailabilityCommands` decides checkout, date edits, and
  overdue under the item lock with these functions; the operator queue
  (`Dhc.Inventory.OperatorLoanQueue`) and both loan projections use the
  *same* functions to advertise readiness and lateness. That is what keeps
  an advisory `ready_for_checkout?` from drifting away from the gate the
  command applies: it may be stale, but it can never be computed by a
  different rule.

  Every function here is pure. `today` is always a parameter — resolving the
  club's calendar day (`Dhc.ClubCalendar.today/0`) is the caller's
  job, so a batch read judges every row against one day.
  """

  alias Dhc.Inventory.Loan

  @typedoc "Availability statuses under which a handover cannot happen."
  @type blocking_status :: :maintenance | :archived

  @blocking_statuses [:maintenance, :archived]

  @doc """
  Whether a checked-out loan is past its approved due date (story 41).

  Derived, never stored: extending the due date makes a loan on time again
  with no transition to undo, and a closed loan is never overdue however late
  it was.
  """
  @spec overdue?(Loan.t(), Date.t()) :: boolean()
  def overdue?(%Loan{status: "checked_out", approved_due_on: %Date{} = due_on}, %Date{} = today),
    do: Date.compare(today, due_on) == :gt

  def overdue?(%Loan{}, %Date{}), do: false

  @doc """
  Whether `today` lies inside the loan's approved window, both ends inclusive.

  A loan with no approved dates has no window and is never within it.
  """
  @spec within_window?(Loan.t(), Date.t()) :: boolean()
  def within_window?(
        %Loan{approved_start_on: %Date{} = starts_on, approved_due_on: %Date{} = due_on},
        %Date{} = today
      ) do
    Date.compare(today, starts_on) != :lt and Date.compare(today, due_on) != :gt
  end

  def within_window?(%Loan{}, %Date{}), do: false

  @doc """
  Whether the item's availability blocks a handover.

  Only maintenance and archival block: `:on_loan` is expected — the loan
  being handed over is itself what holds the item.
  """
  @spec handover_blocked?(%{status: atom()} | nil) :: boolean()
  def handover_blocked?(%{status: status}), do: status in @blocking_statuses
  def handover_blocked?(nil), do: false

  @doc """
  Whether a due date is on or after its start date.
  """
  @spec ordered?(Date.t(), Date.t()) :: boolean()
  def ordered?(%Date{} = starts_on, %Date{} = due_on), do: Date.compare(due_on, starts_on) != :lt

  @doc """
  Whether a member-requested start is today or later.
  """
  @spec requestable_start?(Date.t(), Date.t()) :: boolean()
  def requestable_start?(%Date{} = starts_on, %Date{} = today),
    do: Date.compare(starts_on, today) != :lt

  @doc """
  Whether a due date is on or after the club-calendar day of the handover.

  Once the item has changed hands, `due >= start` is not enough: the approved
  start may predate the handover, so a due date can satisfy ordering and still
  describe a loan that ended before it began (ALE-273). The handover day itself
  is legal — a same-day return is a real loan.
  """
  @spec due_on_or_after_handover?(Date.t(), Date.t()) :: boolean()
  def due_on_or_after_handover?(%Date{} = due_on, %Date{} = handover_day),
    do: Date.compare(due_on, handover_day) != :lt
end
