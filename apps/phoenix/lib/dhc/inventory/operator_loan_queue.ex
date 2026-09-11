defmodule Dhc.Inventory.OperatorLoanQueue do
  @moduledoc """
  ALE-297 (ALE-286b): the shared operator loan queue behind `Dhc.Inventory`.

  Where `Dhc.Inventory.OperatorLoans` owns the transitions an operator makes
  and `Dhc.Inventory.OperatorItemLifecycle` owns the ones that change an
  item, this slice answers the only question a duty officer actually has:
  **what is the next physical action?** (story 62). It is a read model, not a
  command surface.

  ## Four buckets, and every open loan in exactly one

    * **`pending_requests`** — `requested` loans awaiting a decision, oldest
      first, because the member who asked first has waited longest.
    * **`handovers_due`** — `approved` loans whose approved start has arrived,
      earliest start first. Each row carries `ready_for_checkout?`, so a loan
      whose window has *lapsed* is still visible with the action it actually
      needs (a date fix) rather than silently dropping out of the queue.
    * **`returns_and_overdue`** — `checked_out` loans, earliest approved due
      date first, so the most overdue is the top action. Returns and overdue
      share one bucket because they are one physical action — get the item
      back — and overdue is only a derived urgency on it, never a state.
    * **`open_maintenance`** — items with an unended maintenance period,
      longest open first.

  An `approved` loan whose start is still in the future is deliberately in no
  bucket: there is nothing to hand over today. Every *other* open loan is in
  exactly one bucket, so nothing an operator must act on falls through
  (story 50). Closed loans — rejected, cancelled, returned — are finished
  work and never appear, however late a returned loan was.

  ## Counts cannot disagree with their rows

  Every bucket is `%{count: n, rows: [...]}` where `count` is the length of
  `rows`. The queue reads *all* open loans in one query and partitions them
  in memory, so there is no second aggregate query that could count a
  different set than the operator is looking at. That also means the queue is
  deliberately unpaginated: a count that excluded rows beyond a page would be
  the exact disagreement this shape exists to prevent, and the open-loan set
  is bounded by the club's physical items.

  ## No ownership

  The queue is shared. `get_operator_loan_queue/0` takes no actor and has no
  claim, assignment, or lock semantics: any duty officer sees the same thing
  (story 50). Operator authority is equal for quartermaster, president, and
  admin, and is enforced at the contract (ALE-286c), not re-derived here.

  ## Derived facts come from where they already live

  Overdue derives from the approved due date in
  `Dhc.Inventory.ClubCalendar.today/0` — the same rule as ALE-296, reached
  through the same projection rather than re-derived. Rows *are*
  `Dhc.Inventory.OperatorLoans.operator_view/2`, so a queue row and the
  operator detail read can never disagree about status, overdue, or dates.
  Availability comes from `Dhc.Inventory.ItemProjection` in batch, so the
  queue cannot drift from the catalog and no bucket becomes N+1.

  `ready_for_checkout?` is advisory, not authoritative: the queue reads
  without locks, so a fact can move under it between the read and the tap.
  `Dhc.Inventory.OperatorLoans.check_out_loan/3` re-decides everything under
  the item lock, which is what makes a stale `true` safe — the command
  refuses it.

  ## Operator-only, by construction

  Rows name the borrower, disclose the container path, and carry maintenance
  reasons, because the queue is operator-only and there is nothing to
  withhold. These rows must never reach a member read. That is not a matter of
  filtering fields: the member catalog and own-loan read model (ALE-285) is a
  **separate read model**, not a role variant of this one, and its rows cannot
  express borrower identity or an operator maintenance fact at all.
  """

  import Ecto.Query

  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Inventory.OperatorLoans
  alias Dhc.Repo

  # Everything an operator can still act on. The closed statuses
  # (`rejected`, `cancelled`, `returned`) are finished work.
  @open_statuses ~w(requested approved checked_out)

  # Availability statuses that stop a handover. `:on_loan` does not: for an
  # approved loan, the loan holding the item *is this one*. Archive and
  # maintenance are both already refused while a loan is active
  # (`OperatorItemLifecycle`), so this is a defence against a write outside
  # the seam rather than an ordinary path — and it is the same fact
  # `check_out_loan/3` refuses with `:maintenance_open`.
  @handover_blocking_statuses [:maintenance, :archived]

  @typedoc """
  One bucket: its rows and a count derived from exactly those rows.
  """
  @type bucket(row) :: %{count: non_neg_integer(), rows: [row]}

  @typedoc """
  One loan in a queue bucket.

  `Dhc.Inventory.OperatorLoans.operator_view/2` verbatim, so a queue row and
  the operator detail read are the same projection.
  """
  @type loan_row :: OperatorLoans.operator_loan()

  @typedoc """
  One loan in the handovers bucket.

  `ready_for_checkout?` is whether `check_out_loan/3` would accept it right
  now: the approved window contains today and nothing else holds the item.
  Present only here, because the handovers bucket is the one whose next
  action is gated.
  """
  @type handover_row :: %{optional(atom()) => term(), ready_for_checkout?: boolean()}

  @typedoc """
  One item with an open maintenance period. `item_label` is the derived
  catalog label, not a stored name.
  """
  @type maintenance_row :: %{
          id: String.t(),
          item_id: String.t(),
          item_slug: String.t() | nil,
          item_label: String.t(),
          started_at: DateTime.t(),
          started_by_principal_id: String.t() | nil,
          start_reason: String.t() | nil
        }

  @type queue :: %{
          pending_requests: bucket(loan_row()),
          handovers_due: bucket(handover_row()),
          returns_and_overdue: bucket(loan_row()),
          open_maintenance: bucket(maintenance_row())
        }

  @doc """
  The shared operator loan queue, bucketed by lifecycle and due date.

  Takes no actor: the queue is shared and identical for every operator.
  """
  @spec get_operator_loan_queue() :: queue()
  def get_operator_loan_queue do
    today = ClubCalendar.today()
    by_status = Enum.group_by(open_loans(), & &1.status)

    %{
      pending_requests: bucket(pending_rows(status(by_status, "requested"), today)),
      handovers_due: bucket(handover_rows(status(by_status, "approved"), today)),
      returns_and_overdue: bucket(return_rows(status(by_status, "checked_out"), today)),
      open_maintenance: bucket(maintenance_rows())
    }
  end

  # The count is the length of the rows beside it, so the two cannot disagree.
  defp bucket(rows), do: %{count: length(rows), rows: rows}

  defp status(by_status, status), do: Map.get(by_status, status, [])

  # One query for every open loan, so each bucket and its count come from the
  # same facts. `created_at`/`id` ordering here is the stable tie-break every
  # bucket inherits: the per-bucket sorts below are stable, so loans sharing a
  # date stay in the order they were created.
  defp open_loans do
    from(l in Loan,
      where: l.status in @open_statuses,
      order_by: [asc: l.created_at, asc: l.id]
    )
    |> Repo.all()
  end

  # ── Pending requests ────────────────────────────────────────────

  # Oldest first: the member who asked first has waited longest, and there is
  # no queue or entitlement to express beyond that (story 34).
  defp pending_rows(requested, today), do: Enum.map(requested, &view(&1, today))

  # ── Handovers due ───────────────────────────────────────────────

  # Every approved loan whose start has arrived, including one whose window
  # has lapsed: it still holds the item, so hiding it would let real work
  # fall through. `ready_for_checkout?` is what distinguishes "hand it over"
  # from "fix the dates first".
  defp handover_rows(approved, today) do
    due = Enum.filter(approved, &handover_due?(&1, today))
    availabilities = availability_by_item(due)

    due
    |> Enum.sort_by(&Date.to_gregorian_days(&1.approved_start_on))
    |> Enum.map(fn %Loan{} = loan ->
      loan
      |> view(today)
      |> Map.put(:ready_for_checkout?, ready_for_checkout?(loan, today, availabilities))
    end)
  end

  # A future start is not yet due — there is nothing to hand over today. A
  # loan with no approved start could not be checked out at all, so it has no
  # handover action either.
  defp handover_due?(%Loan{approved_start_on: %Date{} = starts_on}, today),
    do: Date.compare(starts_on, today) != :gt

  defp handover_due?(%Loan{}, _today), do: false

  # Exactly the gate `check_out_loan/3` applies: the approved window contains
  # today, and nothing other than this loan holds the item.
  defp ready_for_checkout?(%Loan{} = loan, today, availabilities) do
    within_window?(loan, today) and not blocked?(loan, availabilities)
  end

  defp within_window?(
         %Loan{approved_start_on: %Date{} = starts_on, approved_due_on: %Date{} = due_on},
         today
       ) do
    Date.compare(today, starts_on) != :lt and Date.compare(today, due_on) != :gt
  end

  defp within_window?(%Loan{}, _today), do: false

  defp blocked?(%Loan{item_id: item_id}, availabilities) do
    case Map.get(availabilities, item_id) do
      %{status: status} -> status in @handover_blocking_statuses
      nil -> false
    end
  end

  # Batched through the shared projection, so a bucket costs a fixed number of
  # queries and the queue decides availability by the same precedence rules
  # the catalog does.
  defp availability_by_item([]), do: %{}

  defp availability_by_item(loans) do
    loans
    |> Enum.map(& &1.item_id)
    |> Enum.uniq()
    |> load_items()
    |> ItemProjection.availability_by_item()
  end

  defp load_items([]), do: []
  defp load_items(item_ids), do: Repo.all(from(i in Item, where: i.id in ^item_ids))

  # ── Returns and overdue ─────────────────────────────────────────

  # One bucket, because getting the item back is one physical action; overdue
  # is a derived urgency on it, so the most overdue sorts to the top.
  defp return_rows(checked_out, today) do
    checked_out |> Enum.sort_by(&due_order/1) |> Enum.map(&view(&1, today))
  end

  # A loan with no approved due date cannot be overdue and has no position in
  # a due-date order, so it sorts last: in Erlang term order every atom
  # follows every integer.
  defp due_order(%Loan{approved_due_on: %Date{} = due_on}), do: Date.to_gregorian_days(due_on)
  defp due_order(%Loan{}), do: :undated

  # ── Open maintenance ────────────────────────────────────────────

  # Longest open first: a period nobody has closed is the one most likely to
  # have been forgotten. Archived items are excluded — archival closes any
  # open period atomically (ALE-294), so a surviving row would be advertising
  # work on a retired item.
  defp maintenance_rows do
    periods = Repo.all(open_period_query())
    labels = labels_by_item(Enum.map(periods, fn {_period, item} -> item end))

    Enum.map(periods, fn {%MaintenancePeriod{} = period, %Item{} = item} ->
      %{
        id: period.id,
        item_id: item.id,
        item_slug: item.slug,
        item_label: Map.get(labels, item.id),
        started_at: period.started_at,
        started_by_principal_id: period.started_by_principal_id,
        start_reason: period.start_reason
      }
    end)
  end

  defp open_period_query do
    from(p in MaintenancePeriod,
      join: i in Item,
      on: i.id == p.item_id,
      where: is_nil(p.ended_at),
      where: is_nil(i.archived_at),
      order_by: [asc: p.started_at, asc: p.id],
      select: {p, i}
    )
  end

  # The label is derived, never stored, so it comes from the shared
  # projection in batch rather than being rebuilt here — a maintenance row and
  # the catalog name the same item the same way.
  defp labels_by_item([]), do: %{}

  defp labels_by_item(items) do
    items |> ItemProjection.project_all() |> Map.new(&{&1.id, &1.label})
  end

  # ── Projection ──────────────────────────────────────────────────

  # Rows go through the operator projection rather than being rebuilt, so the
  # queue cannot disagree with `get_operator_loan/1` about status, overdue, or
  # dates. `today` is resolved once for the whole queue, so every row is
  # judged against the same club-calendar day.
  defp view(%Loan{} = loan, today), do: OperatorLoans.operator_view(loan, today)
end
