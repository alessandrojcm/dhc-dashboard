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
  reserved the item or handed it over. The member's repeated-tap concern
  belongs to a member's own cancel button, not to an operator queue.

  ## Overdue is derived

  A `checked_out` loan past its approved due date in
  `Dhc.Inventory.ClubCalendar` days is overdue. It is never a status, so
  extending the due date makes a loan on time again with no transition to
  undo (story 41), and a closed loan is never overdue however late it was.

  ## Serialization

  Every command here changes availability, so every command runs in one
  outer transaction that locks the **item** `FOR UPDATE` before the loan
  row — the same order as `Dhc.Inventory.OperatorItemLifecycle` and
  `Dhc.Inventory.MemberLoans.lock_own_loan/2`. Locking the loan first would
  deadlock against a member cancellation holding the loan and wanting the
  item. Commands are reached by *loan* id, so the item id is resolved
  unlocked purely to learn which item to lock; status and allocation are then
  re-resolved under the item lock, so nothing is decided from the unlocked
  read.

  The item lock settles command-against-command. The partial unique index
  `inventory_loans_one_active_allocation_per_item` is the backstop for
  anything writing outside this seam, and it is *translated*
  (`unique_constraint/3` + `Repo.update` + `case`, never a bang call), so a
  race is a domain conflict (`:already_allocated`) and never a
  `Postgrex.Error`.

  ## Notifications

  None, on purpose. ALE-298 attaches keyed notifications *after* these
  commands return, through `Dhc.Inventory.notify_loan_transition/2`. Wiring
  `Dhc.Notifications.create/2` here would create exactly the duplicate
  notification problem the keyed seam exists to prevent. Every transition
  this module writes is a durable row, so the HTTP layer can name the
  logical event without reshaping these commands.
  """

  import Ecto.Query

  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.Loan
  alias Dhc.Repo

  @max_note_length 1000

  @competing_request_note "Rejected automatically: another request for this item was approved."

  @container_path_separator " › "

  @typedoc """
  One loan as an operator sees it.

  Unlike `Dhc.Inventory.MemberLoans.member_loan/0` this projection names the
  borrower and always carries the container path: the operator queue is
  operator-only, so there is nothing to withhold. It must never be handed to
  a member read — the member catalog and own-loan projections are a separate
  read model (ALE-285), not a role variant of this one.
  """
  @type operator_loan :: %{
          id: String.t(),
          item_id: String.t(),
          borrower_principal_id: String.t(),
          status: String.t(),
          overdue?: boolean(),
          requested_start_on: Date.t(),
          requested_due_on: Date.t(),
          approved_start_on: Date.t() | nil,
          approved_due_on: Date.t() | nil,
          checked_out_at: DateTime.t() | nil,
          returned_at: DateTime.t() | nil,
          decided_at: DateTime.t() | nil,
          decided_by_principal_id: String.t() | nil,
          returned_by_principal_id: String.t() | nil,
          request_note: String.t() | nil,
          decision_note: String.t() | nil,
          item_slug: String.t(),
          item_label: String.t(),
          container_path: String.t() | nil,
          created_at: DateTime.t()
        }

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

  # ── Approve ─────────────────────────────────────────────────────

  @doc """
  Approve one pending request, reserving the item exactly once.

  `attrs` may carry `startsOn` and `dueOn` to adjust the dates at approval
  time, plus an optional `note`. Every other pending request for the same
  item is rejected in the same transaction, so a second operator cannot
  allocate the item from a stale queue.

  Unlike a member request, the approved start may be in the past: by the time
  an operator decides, the requested start can legitimately have passed, and
  the record should say what actually happened.
  """
  @spec approve_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def approve_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id) do
    transact(fn -> locked_approve(loan_id, attrs, actor_id) end)
  end

  defp locked_approve(loan_id, attrs, actor_id) do
    with {:ok, %Loan{} = loan, %Item{} = item} <- lock_loan_and_item(loan_id),
         :ok <- require_status(loan, "requested", :not_pending),
         {:ok, note} <- optional_note(take(attrs, ["note", :note])),
         {:ok, starts_on, due_on} <- approval_dates(loan, attrs),
         :ok <- require_allocatable(item),
         {:ok, %Loan{} = approved} <-
           write_approval(loan, item, starts_on, due_on, note, actor_id) do
      reject_competing_requests(item.id, approved.id, actor_id)
      {:ok, approved}
    end
  end

  # The item lock has already serialized this against every other
  # availability-changing command, so an unavailable item here means a
  # committed maintenance period, archive, or allocation — not a race.
  defp require_allocatable(%Item{} = item) do
    case ItemProjection.availability(item) do
      %{available?: true} -> :ok
      %{available?: false} -> {:error, :item_unavailable}
    end
  end

  # `unique_constraint/3` on the active-allocation index turns a write from
  # outside this seam into a domain conflict instead of a `Postgrex.Error`.
  defp write_approval(%Loan{} = loan, %Item{} = item, starts_on, due_on, note, actor_id) do
    loan
    |> Ecto.Changeset.change(%{
      status: "approved",
      approved_start_on: starts_on,
      approved_due_on: due_on,
      decided_at: DateTime.utc_now(),
      decided_by_principal_id: actor_id,
      decision_note: note,
      # Captured at approval because approval is the entitlement to collect
      # (story 15); a later move does not rewrite where the borrower was told
      # to go.
      approved_container_path_snapshot: container_path(item.container_id)
    })
    |> Ecto.Changeset.unique_constraint(:item_id,
      name: :inventory_loans_one_active_allocation_per_item
    )
    |> Repo.update()
    |> case do
      {:ok, %Loan{} = approved} -> {:ok, approved}
      {:error, %Ecto.Changeset{}} -> {:error, :already_allocated}
    end
  end

  # Allocation is exactly-once, so the competitors are closed here rather
  # than left pending for a second decision. This is a system rejection, and
  # story 49 explicitly gives it no notification.
  defp reject_competing_requests(item_id, approved_id, actor_id) do
    now = DateTime.utc_now()

    from(l in Loan,
      where: l.item_id == ^item_id,
      where: l.id != ^approved_id,
      where: l.status == "requested"
    )
    |> Repo.update_all(
      set: [
        status: "rejected",
        decided_at: now,
        decided_by_principal_id: actor_id,
        decision_note: @competing_request_note,
        updated_at: now
      ]
    )

    :ok
  end

  # ── Reject ──────────────────────────────────────────────────────

  @doc """
  Reject one pending request with an optional operator note.

  Reserves nothing, so the item stays available for another request.
  """
  @spec reject_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def reject_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id) do
    transact(fn ->
      locked_decision(loan_id, attrs, actor_id, "requested", :not_pending, "rejected")
    end)
  end

  @doc """
  Cancel one **approved** loan as an operator.

  A pending request is rejected instead, and a checked-out loan is released
  by a return: after handover the member physically holds the item. Member
  cancellation of their own requested or approved loan stays in
  `Dhc.Inventory.MemberLoans` and is not duplicated here.
  """
  @spec cancel_operator_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def cancel_operator_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id) do
    transact(fn ->
      locked_decision(loan_id, attrs, actor_id, "approved", :not_approved, "cancelled")
    end)
  end

  # Reject and operator-cancel differ only in the status they require and the
  # one they write, so they share this body rather than drifting apart.
  defp locked_decision(loan_id, attrs, actor_id, required, error, target) do
    with {:ok, %Loan{} = loan, %Item{}} <- lock_loan_and_item(loan_id),
         :ok <- require_status(loan, required, error),
         {:ok, note} <- optional_note(take(attrs, ["note", :note])) do
      {:ok,
       loan
       |> Ecto.Changeset.change(%{
         status: target,
         decided_at: DateTime.utc_now(),
         decided_by_principal_id: actor_id,
         decision_note: note
       })
       |> Repo.update!()}
    end
  end

  # ── Checkout ────────────────────────────────────────────────────

  @doc """
  Hand an approved item over to its borrower.

  Gated to an `approved` loan whose approved window contains today in the
  club's calendar and whose item is not in maintenance. An early or late
  handover is recorded by editing the dates first (`edit_loan_dates/3`) and
  then checking out, so the loan's dates and the physical facts agree rather
  than the command silently widening the window.
  """
  @spec check_out_loan(String.t(), map(), String.t()) ::
          {:ok, operator_loan()}
          | {:error, transition_error()}
          | {:error, :outside_window}
          | {:error, :maintenance_open}
  def check_out_loan(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id) do
    transact(fn -> locked_check_out(loan_id, attrs, actor_id) end)
  end

  defp locked_check_out(loan_id, _attrs, actor_id) do
    with {:ok, %Loan{} = loan, %Item{} = item} <- lock_loan_and_item(loan_id),
         :ok <- require_status(loan, "approved", :not_approved),
         :ok <- refuse_maintenance(item),
         :ok <- require_within_window(loan) do
      {:ok,
       loan
       |> Ecto.Changeset.change(%{
         status: "checked_out",
         # The actual handover time is its own fact, kept separate from the
         # approved dates it is checked against.
         checked_out_at: DateTime.utc_now(),
         decided_by_principal_id: actor_id
       })
       |> Repo.update!()}
    end
  end

  # An archived item cannot reach here: archival is blocked by an approved
  # loan (ALE-294), so only maintenance can have opened underneath.
  defp refuse_maintenance(%Item{id: item_id}) do
    if ItemProjection.open_maintenance?(item_id),
      do: {:error, :maintenance_open},
      else: :ok
  end

  defp require_within_window(%Loan{approved_start_on: starts_on, approved_due_on: due_on}) do
    today = ClubCalendar.today()

    cond do
      is_nil(starts_on) or is_nil(due_on) -> {:error, :outside_window}
      Date.compare(today, starts_on) == :lt -> {:error, :outside_window}
      Date.compare(today, due_on) == :gt -> {:error, :outside_window}
      true -> :ok
    end
  end

  # ── Return ──────────────────────────────────────────────────────

  @doc """
  Return a checked-out item, releasing it immediately.

  There is no condition outcome and no inspection step: a fault is recorded
  as an item note or a maintenance period, which keeps handover simple and
  the lifecycle free of a condition subdomain.
  """
  @spec return_loan(String.t(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def return_loan(loan_id, actor_id) when is_binary(loan_id) and is_binary(actor_id) do
    transact(fn -> locked_return(loan_id, actor_id) end)
  end

  defp locked_return(loan_id, actor_id) do
    with {:ok, %Loan{} = loan, %Item{}} <- lock_loan_and_item(loan_id),
         :ok <- require_status(loan, "checked_out", :not_checked_out) do
      {:ok,
       loan
       |> Ecto.Changeset.change(%{
         status: "returned",
         returned_at: DateTime.utc_now(),
         returned_by_principal_id: actor_id
       })
       |> Repo.update!()}
    end
  end

  # ── Date edits ──────────────────────────────────────────────────

  @doc """
  Edit the approved dates of a live loan.

  The start is editable while the loan is only `approved` and immutable once
  it is `checked_out`: the item has physically changed hands, so moving the
  start would rewrite a fact. The due date stays editable in both states,
  including after checkout, which is what makes a due-date correction
  possible without cancelling and re-approving (ALE-279).

  Omitted dates are left as they are, so an edit that only pushes the due
  date out does not have to restate the start.
  """
  @spec edit_loan_dates(String.t(), map(), String.t()) ::
          {:ok, operator_loan()} | {:error, transition_error()}
  def edit_loan_dates(loan_id, attrs, actor_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(actor_id) do
    transact(fn -> locked_edit_dates(loan_id, attrs, actor_id) end)
  end

  defp locked_edit_dates(loan_id, attrs, _actor_id) do
    with {:ok, %Loan{} = loan, %Item{}} <- lock_loan_and_item(loan_id),
         :ok <- require_editable(loan),
         {:ok, starts_on, due_on} <- edited_dates(loan, attrs) do
      {:ok,
       loan
       |> Ecto.Changeset.change(%{approved_start_on: starts_on, approved_due_on: due_on})
       |> Repo.update!()}
    end
  end

  defp require_editable(%Loan{status: status}) when status in ~w(approved checked_out), do: :ok
  defp require_editable(%Loan{}), do: {:error, :not_editable}

  # ── Operator read ───────────────────────────────────────────────

  @doc """
  One loan as an operator sees it, borrower included.
  """
  @spec get_operator_loan(String.t()) :: {:ok, operator_loan()} | {:error, :not_found}
  def get_operator_loan(loan_id) when is_binary(loan_id) do
    with {:ok, id} <- cast_id(loan_id),
         %Loan{} = loan <- Repo.one(from(l in Loan, where: l.id == ^id)) do
      {:ok, operator_view(loan, ClubCalendar.today())}
    else
      _absent -> {:error, :not_found}
    end
  end

  @doc """
  The one place a loan row becomes an operator read model.

  Public for `Dhc.Inventory.OperatorLoanQueue` (ALE-297), which projects the
  same rows: a queue row and this module's detail read must not be able to
  disagree about status, overdue, or dates. `today` is a parameter so a caller
  projecting many rows resolves the club's calendar day once and judges every
  row against the same day, rather than straddling midnight mid-list.

  Not part of the `Dhc.Inventory` public surface — callers outside the
  inventory slices reach loans through the context.
  """
  @spec operator_view(Loan.t(), Date.t()) :: operator_loan()
  def operator_view(%Loan{} = loan, %Date{} = today) do
    %{
      id: loan.id,
      item_id: loan.item_id,
      borrower_principal_id: loan.borrower_principal_id,
      status: loan.status,
      overdue?: overdue?(loan, today),
      requested_start_on: loan.requested_start_on,
      requested_due_on: loan.requested_due_on,
      approved_start_on: loan.approved_start_on,
      approved_due_on: loan.approved_due_on,
      checked_out_at: loan.checked_out_at,
      returned_at: loan.returned_at,
      decided_at: loan.decided_at,
      decided_by_principal_id: loan.decided_by_principal_id,
      returned_by_principal_id: loan.returned_by_principal_id,
      request_note: loan.request_note,
      decision_note: loan.decision_note,
      item_slug: loan.item_slug_snapshot,
      item_label: loan.item_label_snapshot,
      container_path: loan.approved_container_path_snapshot,
      created_at: loan.created_at
    }
  end

  # Overdue is derived, never stored (story 41): a checked-out loan past its
  # approved due date is late, and pushing the date out makes it on time again
  # with no transition to undo. A closed loan is never overdue.
  defp overdue?(%Loan{status: "checked_out", approved_due_on: %Date{} = due_on}, %Date{} = today),
    do: Date.compare(today, due_on) == :gt

  defp overdue?(%Loan{}, %Date{}), do: false

  # ── Locking ─────────────────────────────────────────────────────

  # Every command here is reached by loan id but changes item availability,
  # so it must take the **item** lock first — the order
  # `OperatorItemLifecycle` and `MemberLoans` use. The unlocked read below
  # answers only "which item?"; the loan itself is then re-read `FOR UPDATE`
  # under the item lock, so no decision rests on the unlocked row.
  defp lock_loan_and_item(loan_id) do
    with {:ok, id} <- cast_id(loan_id),
         {:ok, item_id} <- loan_item_id(id),
         {:ok, %Item{} = item} <- ItemGuards.lock_item(item_id),
         {:ok, %Loan{} = loan} <- lock_loan(id) do
      {:ok, loan, item}
    end
  end

  defp loan_item_id(id) do
    case Repo.one(from(l in Loan, where: l.id == ^id, select: l.item_id)) do
      nil -> {:error, :not_found}
      item_id -> {:ok, item_id}
    end
  end

  defp lock_loan(id) do
    case Repo.one(from(l in Loan, where: l.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      %Loan{} = loan -> {:ok, loan}
    end
  end

  defp require_status(%Loan{status: status}, status, _error), do: :ok
  defp require_status(%Loan{}, _required, error), do: {:error, error}

  # ── Dates ───────────────────────────────────────────────────────

  # Approval defaults to the dates the member asked for, so an operator who
  # simply agrees does not have to restate them.
  defp approval_dates(%Loan{} = loan, attrs) do
    with {:ok, starts_on} <- date_or(take_start(attrs), loan.requested_start_on),
         {:ok, due_on} <- date_or(take_due(attrs), loan.requested_due_on),
         :ok <- require_ordered(starts_on, due_on) do
      {:ok, starts_on, due_on}
    end
  end

  # An edit leaves an omitted date alone, and falls back to the requested
  # date only if the loan somehow has no approved one.
  defp edited_dates(%Loan{} = loan, attrs) do
    current_start = loan.approved_start_on || loan.requested_start_on
    current_due = loan.approved_due_on || loan.requested_due_on

    with {:ok, starts_on} <- date_or(take_start(attrs), current_start),
         :ok <- require_start_unchanged(loan, starts_on, current_start),
         {:ok, due_on} <- date_or(take_due(attrs), current_due),
         :ok <- require_ordered(starts_on, due_on),
         :ok <- require_not_before_handover(loan, due_on) do
      {:ok, starts_on, due_on}
    end
  end

  # Once the item has changed hands, `due_on >= starts_on` is not enough: the
  # approved start may legitimately predate the handover, so a due date could
  # satisfy the ordering rule and still fall before the member actually took
  # the item, describing a loan that ended before it began (ALE-273). The
  # handover *day* itself is legal — a same-day return is a real loan.
  defp require_not_before_handover(%Loan{checked_out_at: %DateTime{} = at}, due_on) do
    if Date.compare(due_on, ClubCalendar.on_date(at)) == :lt,
      do: {:error, :invalid_dates},
      else: :ok
  end

  defp require_not_before_handover(%Loan{}, _due_on), do: :ok

  # Restating the same start after checkout is not a change, so only a real
  # move is refused.
  defp require_start_unchanged(%Loan{status: "checked_out"}, starts_on, current_start) do
    if Date.compare(starts_on, current_start) == :eq, do: :ok, else: {:error, :start_immutable}
  end

  defp require_start_unchanged(%Loan{}, _starts_on, _current), do: :ok

  defp date_or(nil, fallback), do: {:ok, fallback}
  defp date_or(%Date{} = date, _fallback), do: {:ok, date}

  defp date_or(value, _fallback) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_dates}
    end
  end

  defp date_or(_value, _fallback), do: {:error, :invalid_dates}

  defp require_ordered(starts_on, due_on) do
    if Date.compare(due_on, starts_on) == :lt, do: {:error, :invalid_dates}, else: :ok
  end

  defp take_start(attrs), do: take(attrs, ["startsOn", "starts_on", :startsOn, :starts_on])
  defp take_due(attrs), do: take(attrs, ["dueOn", "due_on", :dueOn, :due_on])

  # ── Container path ──────────────────────────────────────────────

  # The full path from the root, so a borrower reads "Clubhouse › Rack 2"
  # rather than a bare shelf name they cannot locate. Snapshotted at
  # approval, never re-derived afterwards.
  defp container_path(nil), do: nil

  defp container_path(container_id) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT id, parent_container_id, name, 0 AS depth
          FROM containers
          WHERE id = $1
          UNION ALL
          SELECT parent.id, parent.parent_container_id, parent.name, child.depth + 1
          FROM containers parent
          JOIN ancestors child ON child.parent_container_id = parent.id
        )
        SELECT name FROM ancestors ORDER BY depth DESC
        """,
        [Ecto.UUID.dump!(container_id)]
      )

    case result.rows do
      [] -> nil
      rows -> Enum.map_join(rows, @container_path_separator, fn [name] -> name end)
    end
  end

  # ── Notes ───────────────────────────────────────────────────────

  # Blank is absence, matching the member and item seams; anything
  # non-textual is rejected rather than silently coerced.
  defp optional_note(nil), do: {:ok, nil}

  defp optional_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:ok, nil}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_note_length)}
    end
  end

  defp optional_note(_note), do: {:error, :invalid_note}

  # ── Helpers ─────────────────────────────────────────────────────

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp take(params, keys) when is_map(params) do
    Enum.find_value(keys, fn key ->
      if is_map_key(params, key), do: {:present, Map.get(params, key)}, else: nil
    end)
    |> case do
      nil -> nil
      {:present, value} -> value
    end
  end

  # Each command's body returns either a loan row to project or a domain
  # reason to roll back, so the transaction wrapper and the projection live
  # in one place instead of being repeated per command.
  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, %Loan{} = loan} -> loan
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Loan{} = loan} -> {:ok, operator_view(loan, ClubCalendar.today())}
      {:error, reason} -> {:error, reason}
    end
  end
end
