defmodule Dhc.Inventory.OperatorLoans do
  @moduledoc """
  ALE-296 (ALE-286a): the operator half of the loan lifecycle behind
  `Dhc.Inventory`.

  Where `Dhc.Inventory.MemberLoans` owns what a borrower may do to their own
  loan — request, cancel before checkout, read their history — this slice
  owns every decision an operator makes about someone else's:

    * **Approve.** The single fair decision point. Approval atomically
      reserves the item and rejects *all* competing pending requests with a
      system note, so allocation is exactly-once (story 35). Dates may be
      adjusted, and the container path is snapshotted here because approval
      is what entitles the borrower to know where to collect (story 15).
    * **Reject.** Closes a pending request with an operator note and reserves
      nothing.
    * **Operator cancel.** Distinct from the member's cancellation: it
      applies only to an *approved* loan (ALE-273). A pending request is
      rejected, and after checkout the member holds the item, so release is a
      return.
    * **Checkout.** Gated to an `approved` loan whose approved window
      contains today and whose item is out of maintenance. The operator
      updates the dates *first* for an early or late handover, so the record
      matches reality rather than being bent by the command (story 37).
    * **Return.** Releases the item immediately. There is no condition
      subdomain — faults route to notes or a maintenance period.
    * **Date edits.** The start is immutable once the item has physically
      changed hands; the due date stays editable, including after checkout
      (ALE-279 supersedes the earlier no-edits rule).

  ## Transitions, and nothing else

  `requested → approved | rejected`, `approved → checked_out | cancelled`,
  `checked_out → returned`. There are no lost or written-off states, no
  queues, entitlements, auto-approval, or revival of a closed loan. A command
  that finds the loan in the wrong state returns a domain reason naming the
  state it needed (`:not_pending`, `:not_approved`, `:not_checked_out`),
  never a generic failure.

  Approval, checkout, and return are *not* idempotent, unlike the member's
  cancellation: each has an allocation or custody side effect, so a caller
  has to be able to tell whether this particular call was the one that
  reserved the item or handed it over.

  ## Where the work happens

  Since GH-508 this module is a **facade**: every command is one
  `Dhc.Inventory.AvailabilityCommands.execute/2` call as an `{:operator, id}`
  actor, and that boundary owns the transaction, the item-before-loan lock
  order, the re-read under the lock, the date and window policy, the
  constraint translation, and the operator projection. Nothing about a
  transition is decided here; adding a rule to a command means adding it
  there, once, where the member and item commands share it.

  ## Notifications

  None, on purpose. ALE-298 attaches keyed notifications *after* these
  commands return, through `Dhc.Inventory.notify_loan_transition/2`. Wiring
  `Dhc.Notifications.create/2` here would create exactly the duplicate
  notification problem the keyed seam exists to prevent.
  """

  import Ecto.Query

  alias Dhc.Inventory.AvailabilityCommands
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanProjection
  alias Dhc.Repo

  @typedoc """
  One loan as an operator sees it — `Dhc.Inventory.LoanProjection.operator_loan/0`.

  Names the borrower and always carries the container path: the operator
  queue is operator-only, so there is nothing to withhold. It must never be
  handed to a member read — the member projections are a separate read model
  (ALE-285), not a role variant of this one.
  """
  @type operator_loan :: LoanProjection.operator_loan()

  @type transition_error ::
          :not_found
          | :not_pending
          | :not_approved
          | :not_checked_out
          | :not_editable
          | :invalid_dates
          | :invalid_note
          | :item_unavailable
          | :already_allocated
          | :start_immutable
          | :unknown_actor

  @doc """
  Approve one pending request, reserving the item exactly once.

  `attrs` may carry `startsOn` and `dueOn` to adjust the dates at approval
  time, plus an optional `note`. Every other pending request for the same
  item is rejected in the same transaction. Unlike a member request, the
  approved start may be in the past.
  """
  @spec approve_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def approve_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:approve_loan, loan_id, attrs})

  @doc """
  Reject one pending request with an optional operator note.
  """
  @spec reject_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def reject_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:reject_loan, loan_id, attrs})

  @doc """
  Cancel one **approved** loan as an operator.

  A pending request is rejected instead, and a checked-out loan is released
  by a return. Member cancellation stays in `Dhc.Inventory.MemberLoans`.
  """
  @spec cancel_operator_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def cancel_operator_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:cancel_loan, loan_id, attrs})

  @doc """
  Hand an approved item over to its borrower.

  Gated to an `approved` loan whose approved window contains today in the
  club's calendar and whose item is not in maintenance.
  """
  @spec check_out_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()}
          | {:error, transition_error()}
          | {:error, :outside_window}
          | {:error, :maintenance_open}
  def check_out_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:check_out_loan, loan_id, attrs})

  @doc """
  Return a checked-out item, releasing it immediately.
  """
  @spec return_loan(String.t(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def return_loan(loan_id, actor_id) when is_binary(loan_id) and is_binary(actor_id),
    do: command(actor_id, {:return_loan, loan_id, %{}})

  @doc """
  Edit the approved dates of a live loan.

  The start is editable while the loan is only `approved` and immutable once
  it is `checked_out`; the due date stays editable in both states. Omitted
  dates are left as they are.
  """
  @spec edit_loan_dates(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def edit_loan_dates(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id),
      do: command(actor_id, {:edit_loan_dates, loan_id, attrs})

  # ── Operator read ───────────────────────────────────────────────

  @doc """
  One loan as an operator sees it, borrower included.
  """
  @spec get_operator_loan(String.t()) :: {:ok, operator_loan()} | {:error, :not_found}
  def get_operator_loan(loan_id) when is_binary(loan_id) do
    with {:ok, id} <- cast_id(loan_id),
         %Loan{} = loan <- Repo.one(from(l in Loan, where: l.id == ^id)) do
      {:ok, LoanProjection.operator_view(loan, ClubCalendar.today())}
    else
      _absent -> {:error, :not_found}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp command(actor_id, command) do
    case AvailabilityCommands.execute({:operator, actor_id}, command) do
      {:ok, {:loan, view}} -> {:ok, view}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
