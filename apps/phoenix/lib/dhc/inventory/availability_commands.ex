defmodule Dhc.Inventory.AvailabilityCommands do
  @moduledoc """
  GH-508: the one transaction boundary for every inventory command that
  changes — or must be serialized against a change of — an item's
  availability.

  `Dhc.Inventory.OperatorItemLifecycle`, `Dhc.Inventory.OperatorLoans`, and
  `Dhc.Inventory.MemberLoans` each own a different set of user-facing
  operations, but every one of them used to reimplement the same protocol:
  resolve the item, take the item lock before any loan lock, re-read under
  the lock, derive availability from facts, validate, write through
  changesets with constraint translation, project for the caller. That
  protocol now lives here exactly once, and the three modules are thin
  facades over `execute/2`.

  ## The protocol

  Every command runs as

      with_locked_item(subject, fn locked ->
        # locked.item is FOR UPDATE; locked.loan, if any, was re-read under it
        validate the transition against the locked state
        persist it through changesets
        project the outcome for the actor
      end)

  inside one `Repo.transaction/1`; a domain reason rolls the transaction back
  and becomes `{:error, reason}`.

  **Lock order is part of the contract.** Commands that depend on a
  container lock that container chain `FOR SHARE` **before** the item
  `FOR UPDATE` — a move locks the destination chain first; a restore
  locks the item's current chain first. That matches container archive,
  which locks the container (and its subtree) before any item row.
  Reversing either pair deadlocks. A restore peeks the item only to
  learn which chain to share-lock; if the locked row sits in a different
  container, the transaction rolls back and retries from a fresh peek
  rather than locking a new chain while holding the item.

  After the item lock come the dependent rows (the loan, the open
  maintenance period, the item's live loans). A command that locked the loan
  first would deadlock against one holding the item and wanting the loan.
  Loan commands are reached by *loan* id, so `with_locked_item/2` reads the
  loan's `item_id` **unlocked** purely to learn which item to lock, takes the
  item lock, and then re-reads the loan `FOR UPDATE`. Nothing — ownership,
  status, dates — is decided from the unlocked row: it may be stale by the
  time the lock is acquired, and a stale prefetch must never authorize a
  transition.

  **Availability is derived, never stored.** `Dhc.Inventory.ItemProjection`
  recomputes it from the archive timestamp, the open maintenance period, and
  the approved/checked-out loans, and this module decides from that under the
  item lock. A pending request is not an availability input (story 34).

  **Constraints are translated, never raised.** The item lock settles
  command-against-command; the partial unique indexes and the principal
  foreign keys are the backstop for anything writing outside this seam, and
  `persist/1` turns each into a stable domain reason (`:already_allocated`,
  `:duplicate_request`, `:maintenance_open`, `:unknown_actor`) rather than a
  `Postgrex.Error`. Competing pending requests closed by an approval, a
  maintenance open, or an archive are written one row at a time through
  `persist/1` as well — never a bulk `update_all`.

  ## Actors

  Role authorization is explicit in the actor value. A member may only
  request for themselves and cancel their own loan; every other command is an
  operator's. The wrong actor gets `{:error, :forbidden}` before any read.
  `:system` is reserved in the type and currently authorizes nothing.

  ## Projections

  Member and operator outcomes are distinct read models built by
  `Dhc.Inventory.LoanProjection`; item outcomes are `ItemProjection.project/1`.
  The member view never carries a borrower or an operator id, and discloses
  the container path only from approval onward (story 15).

  ## Notifications

  None, on purpose. Every transition here is a durable row; the HTTP exposure
  attaches keyed notifications *after* a command returns through
  `Dhc.Inventory.notify_loan_transition/2`. Wiring `Dhc.Notifications` in
  here would recreate exactly the duplicate-notification problem the keyed
  seam exists to prevent.
  """

  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.ItemValues
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanPolicy
  alias Dhc.Inventory.LoanProjection
  alias Dhc.Inventory.MaintenancePeriod
  alias Dhc.Repo

  @type principal_id :: String.t()

  @type actor :: {:operator, principal_id()} | {:member, principal_id()} | :system

  @typedoc """
  A command names its subject by id — or, for items, by slug or id — and
  carries the caller's attributes as they arrived (string or atom keys).
  """
  @type command ::
          {:request_loan, item_slug_or_id :: String.t(), attrs :: map()}
          | {:cancel_request, loan_id :: String.t(), attrs :: map()}
          | {:approve_loan, loan_id :: String.t(), attrs :: map()}
          | {:reject_loan, loan_id :: String.t(), attrs :: map()}
          | {:cancel_loan, loan_id :: String.t(), attrs :: map()}
          | {:check_out_loan, loan_id :: String.t(), attrs :: map()}
          | {:return_loan, loan_id :: String.t(), attrs :: map()}
          | {:edit_loan_dates, loan_id :: String.t(), attrs :: map()}
          | {:move_item, item_slug_or_id :: String.t(), attrs :: map()}
          | {:open_maintenance, item_slug_or_id :: String.t(), attrs :: map()}
          | {:close_maintenance, item_slug_or_id :: String.t(), attrs :: map()}
          | {:retire_item, item_slug_or_id :: String.t(), attrs :: map()}
          | {:reactivate_item, item_slug_or_id :: String.t(), attrs :: map()}

  @type outcome ::
          {:loan, LoanProjection.operator_loan() | LoanProjection.member_loan()}
          | {:item, Item.t()}

  @type reason ::
          :forbidden
          | :unknown_command
          | :not_found
          | :archived
          | :archived_container
          | :archived_category
          | :not_pending
          | :not_approved
          | :not_checked_out
          | :not_cancellable
          | :not_editable
          | :invalid_dates
          | :invalid_note
          | :invalid_text
          | :reason_required
          | :item_unavailable
          | :already_allocated
          | :duplicate_request
          | :start_immutable
          | :outside_window
          | :maintenance_open
          | :no_open_maintenance
          | :loan_active
          | :unknown_actor
          | :retry_exhausted
          | {:invalid_values, %{String.t() => ItemValues.error_reason()}}

  @member_commands ~w(request_loan cancel_request)a

  @operator_commands ~w(
    approve_loan reject_loan cancel_loan check_out_loan return_loan edit_loan_dates
    move_item open_maintenance close_maintenance retire_item reactivate_item
  )a

  @max_text_length 1000
  @restore_attempts 3

  @competing_request_note "Rejected automatically: another request for this item was approved."
  @maintenance_rejection_note "Rejected automatically: the item went into maintenance."
  @archive_rejection_note "Rejected automatically: the item was archived."
  @default_archive_end_note "Ended automatically because the item was archived."

  @container_path_separator " › "

  # Statuses a member may still walk away from; after checkout they hold the
  # item, so only an operator return closes the loan.
  @member_cancellable ~w(requested approved)

  @note_keys ["note", :note]
  @start_keys ["startsOn", "starts_on", :startsOn, :starts_on]
  @due_keys ["dueOn", "due_on", :dueOn, :due_on]
  @reason_keys ["reason", :reason]
  @end_note_keys ["endNote", "end_note", :endNote, :end_note]
  @container_keys ["containerId", "container_id", :containerId, :container_id]

  # Constraint names, as the migrations created them, and the domain reason
  # each becomes. Anything not listed here is a programming error and may
  # raise: the point is that a *race* never surfaces as an exception.
  @unique_constraints %{
    "inventory_loans_one_active_allocation_per_item" => :already_allocated,
    "inventory_loans_one_pending_request_per_item_borrower" => :duplicate_request,
    "inventory_maintenance_periods_one_open_per_item" => :maintenance_open
  }

  @actor_foreign_keys [
    {Loan, :borrower_principal_id, "inventory_loans_borrower_principal_id_fkey"},
    {Loan, :decided_by_principal_id, "inventory_loans_decided_by_principal_id_fkey"},
    {Loan, :returned_by_principal_id, "inventory_loans_returned_by_principal_id_fkey"},
    {MaintenancePeriod, :started_by_principal_id,
     "inventory_maintenance_periods_started_by_principal_id_fkey"},
    {MaintenancePeriod, :ended_by_principal_id,
     "inventory_maintenance_periods_ended_by_principal_id_fkey"},
    {Item, :archived_by_principal_id, "inventory_items_archived_by_principal_id_fkey"},
    {Item, :updated_by, "inventory_items_updated_by_fkey"}
  ]

  @doc """
  Execute one availability-changing command as `actor`.

  Authorizes the actor for the command, then runs the command's transition in
  one transaction under the canonical item lock. Returns the projected outcome
  for the actor's role or a domain reason; never raises on a race.
  """
  @spec execute(actor(), command()) :: {:ok, outcome()} | {:error, reason()}
  def execute(actor, {:reactivate_item, subject, attrs}) when is_map(attrs) do
    with :ok <- authorize(actor, :reactivate_item) do
      restore_transact(actor, subject, attrs, restore_attempts())
    end
  end

  def execute(actor, {name, subject, attrs}) when is_atom(name) and is_map(attrs) do
    with :ok <- authorize(actor, name) do
      transact(fn -> run(actor, name, subject, attrs) end)
    end
  end

  def execute(_actor, _command), do: {:error, :unknown_command}

  # ── Authorization ───────────────────────────────────────────────

  defp authorize({:member, id}, name) when is_binary(id) and name in @member_commands, do: :ok

  defp authorize({:operator, id}, name) when is_binary(id) and name in @operator_commands,
    do: :ok

  defp authorize(_actor, name) when name in @member_commands or name in @operator_commands,
    do: {:error, :forbidden}

  defp authorize(_actor, _name), do: {:error, :unknown_command}

  # ── Member commands ─────────────────────────────────────────────

  # A member requests for themselves only: the borrower is the actor, and
  # there is no borrower parameter to forge.
  defp run({:member, borrower}, :request_loan, subject, attrs) do
    with_locked_item({:item, subject}, fn %{item: item} ->
      with :ok <- require_member_visible(item),
           {:ok, starts_on, due_on} <- request_dates(attrs),
           {:ok, note} <- optional_text(take(attrs, @note_keys), :invalid_note),
           :ok <- require_available(item),
           {:ok, %Loan{} = loan} <-
             persist(request_changeset(item, borrower, starts_on, due_on, note)) do
        member_outcome(loan)
      end
    end)
  end

  # Cancelling an already cancelled loan is a no-op, so a repeated tap is not
  # an error. Someone else's loan is `:not_found`: whether it exists is not a
  # member-visible fact.
  defp run({:member, borrower}, :cancel_request, subject, attrs) do
    with_locked_item({:loan, subject, {:borrower, borrower}}, fn %{loan: loan} ->
      with {:ok, note} <- optional_text(take(attrs, @note_keys), :invalid_note),
           {:ok, %Loan{} = cancelled} <- member_cancellation(loan, note, borrower) do
        member_outcome(cancelled)
      end
    end)
  end

  # ── Operator loan commands ──────────────────────────────────────

  # Approval is the single fair decision point: it reserves the item exactly
  # once, rejects every competing pending request with a system note, and
  # snapshots the container path because approval is what entitles the
  # borrower to know where to collect (story 15).
  defp run({:operator, actor}, :approve_loan, subject, attrs) do
    with_locked_item({:loan, subject, :any}, fn %{item: item, loan: loan} ->
      with :ok <- require_status(loan, "requested", :not_pending),
           {:ok, note} <- optional_text(take(attrs, @note_keys), :invalid_note),
           {:ok, starts_on, due_on} <- approval_dates(loan, attrs),
           :ok <- require_available(item),
           {:ok, %Loan{} = approved} <-
             persist(approval_changeset(loan, item, starts_on, due_on, note, actor)),
           :ok <-
             reject_pending_requests(item.id, actor, @competing_request_note, except: approved.id) do
        operator_outcome(approved)
      end
    end)
  end

  defp run({:operator, actor}, :reject_loan, subject, attrs),
    do: operator_decision(subject, attrs, actor, "requested", :not_pending, "rejected")

  # Distinct from the member's cancellation: it applies only to an *approved*
  # loan. A pending request is rejected; after checkout release is a return.
  defp run({:operator, actor}, :cancel_loan, subject, attrs),
    do: operator_decision(subject, attrs, actor, "approved", :not_approved, "cancelled")

  # Gated to an approved loan whose window contains today in the club's
  # calendar and whose item is not in maintenance. An early or late handover
  # is recorded by editing the dates first, never by widening the window.
  defp run({:operator, actor}, :check_out_loan, subject, _attrs) do
    with_locked_item({:loan, subject, :any}, fn %{item: item, loan: loan} ->
      with :ok <- require_status(loan, "approved", :not_approved),
           :ok <- refuse_handover_block(item),
           :ok <- require_within_window(loan),
           {:ok, %Loan{} = out} <- persist(checkout_changeset(loan, actor)) do
        operator_outcome(out)
      end
    end)
  end

  # Releases the item immediately; there is no condition outcome.
  defp run({:operator, actor}, :return_loan, subject, _attrs) do
    with_locked_item({:loan, subject, :any}, fn %{loan: loan} ->
      with :ok <- require_status(loan, "checked_out", :not_checked_out),
           {:ok, %Loan{} = returned} <- persist(return_changeset(loan, actor)) do
        operator_outcome(returned)
      end
    end)
  end

  # The start is immutable once the item has changed hands; the due date
  # stays editable in both live states (ALE-279). The previous due date
  # and the persist stamp ride on the operator view under keys the JSON
  # renderer does not emit, so the HTTP layer can tell a restatement
  # from a move without a second unlocked read.
  defp run({:operator, _actor}, :edit_loan_dates, subject, attrs) do
    with_locked_item({:loan, subject, :any}, fn %{loan: loan} ->
      previous_due_on = loan.approved_due_on

      with :ok <- require_editable(loan),
           {:ok, starts_on, due_on} <- edited_dates(loan, attrs),
           {:ok, %Loan{} = edited} <-
             persist(
               Ecto.Changeset.change(loan, %{
                 approved_start_on: starts_on,
                 approved_due_on: due_on
               })
             ),
           {:ok, {:loan, view}} <- operator_outcome(edited) do
        {:ok,
         {:loan,
          Map.merge(view, %{
            previous_due_on: previous_due_on,
            due_edit_at: edited.updated_at
          })}}
      end
    end)
  end

  # ── Operator item commands ──────────────────────────────────────

  # Movement touches `container_id` and nothing else, so it can never quietly
  # reclassify or re-value an item. Allowed in maintenance; blocked while a
  # loan holds custody.
  defp run({:operator, actor}, :move_item, subject, attrs) do
    with {:ok, container_id} <-
           ItemGuards.require_active_container(take(attrs, @container_keys)) do
      move_locked(subject, container_id, actor)
    end
  end

  # An item leaves circulation with a reason or not at all. Pending requests
  # are rejected in the same transaction; a live loan blocks instead, because
  # that member already holds the item.
  defp run({:operator, actor}, :open_maintenance, subject, attrs) do
    with_locked_item({:active_item, subject}, fn %{item: item} ->
      with {:ok, reason} <- require_reason(attrs),
           :ok <- refuse_open_maintenance(item.id),
           :ok <- refuse_active_loan(item.id),
           {:ok, %MaintenancePeriod{}} <- persist(period_changeset(item.id, reason, actor)),
           :ok <- reject_pending_requests(item.id, actor, @maintenance_rejection_note) do
        touch_item(item, actor)
      end
    end)
  end

  defp run({:operator, actor}, :close_maintenance, subject, attrs) do
    with_locked_item({:active_item, subject}, fn %{item: item} ->
      with {:ok, note} <- optional_text(take(attrs, @end_note_keys), :invalid_text),
           {:ok, %MaintenancePeriod{} = period} <- lock_open_period(item.id),
           {:ok, %MaintenancePeriod{}} <- persist(close_period_changeset(period, note, actor)) do
        touch_item(item, actor)
      end
    end)
  end

  # Archive replaces deletion once history exists: pending requests are
  # rejected and any open period is closed atomically with an archive note.
  # A live loan blocks it; archiving an archived item is a no-op.
  defp run({:operator, actor}, :retire_item, subject, attrs) do
    with_locked_item({:item, subject}, fn
      %{item: %Item{archived_at: %DateTime{}} = item} ->
        item_outcome(item)

      %{item: item} ->
        with {:ok, reason} <- optional_text(take(attrs, @reason_keys), :invalid_text),
             :ok <- refuse_active_loan(item.id),
             :ok <- close_open_period_for_archive(item.id, reason, actor),
             {:ok, %Item{} = archived} <- persist(archive_changeset(item, actor)),
             :ok <- reject_pending_requests(item.id, actor, @archive_rejection_note) do
          item_outcome(archived)
        end
    end)
  end

  # Restore is gated on the dependencies an active item needs — a live
  # category, an active container chain, and retained values that still
  # validate — because the ALE-283 gates only consider *active* items, so an
  # archived one can drift out of validity while retired.
  defp run({:operator, actor}, :reactivate_item, subject, _attrs) do
    with {:ok, preview} <- peek_item(subject),
         :ok <- lock_preview_container(preview) do
      restore_locked(subject, actor, preview.container_id)
    end
  end

  # ── Shared command bodies ───────────────────────────────────────

  # Destination chain is already share-locked; the item lock comes second.
  defp move_locked(subject, container_id, actor) do
    with_locked_item({:active_item, subject}, fn %{item: item} ->
      with :ok <- refuse_active_loan(item.id),
           {:ok, %Item{} = moved} <-
             persist(
               Ecto.Changeset.change(item, %{container_id: container_id, updated_by: actor})
             ) do
        item_outcome(moved)
      end
    end)
  end

  # The peeked chain is already share-locked. If the locked item still
  # sits in that container, re-read the chain without taking new locks.
  # A different container means a concurrent move; roll back and retry
  # from the peek rather than locking D while holding the item.
  defp restore_locked(subject, actor, peeked_container_id) do
    with_locked_item({:item, subject}, fn
      %{item: %Item{archived_at: nil} = item} ->
        item_outcome(item)

      %{item: item} ->
        with :ok <- require_same_container(item.container_id, peeked_container_id),
             :ok <- require_active_category(item.category_id),
             :ok <- verify_held_container_chain(item.container_id),
             :ok <- require_retained_values_valid(item),
             {:ok, %Item{} = restored} <- persist(restore_changeset(item, actor)) do
          item_outcome(restored)
        end
    end)
  end

  defp require_same_container(actual, peeked) when actual == peeked, do: :ok
  defp require_same_container(_actual, _peeked), do: {:error, :container_moved}

  defp verify_held_container_chain(container_id) do
    if ItemGuards.container_chain_active?(container_id),
      do: :ok,
      else: {:error, :archived_container}
  end

  defp member_cancellation(%Loan{status: "cancelled"} = loan, _note, _borrower), do: {:ok, loan}

  defp member_cancellation(%Loan{status: status} = loan, note, borrower)
       when status in @member_cancellable,
       do: persist(decision_changeset(loan, "cancelled", note, borrower))

  defp member_cancellation(%Loan{}, _note, _borrower), do: {:error, :not_cancellable}

  # Reject and operator-cancel differ only in the status they require and the
  # one they write, so they share one body rather than drifting apart.
  defp operator_decision(subject, attrs, actor, required, error, target) do
    with_locked_item({:loan, subject, :any}, fn %{loan: loan} ->
      with :ok <- require_status(loan, required, error),
           {:ok, note} <- optional_text(take(attrs, @note_keys), :invalid_note),
           {:ok, %Loan{} = decided} <- persist(decision_changeset(loan, target, note, actor)) do
        operator_outcome(decided)
      end
    end)
  end

  # ── The locking primitive ───────────────────────────────────────

  # Items are reached by slug or id and locked directly. Loans are reached by
  # loan id: the unlocked read below answers only "which item?", and the loan
  # is re-read FOR UPDATE under the item lock so nothing is decided from it.
  # `scope` narrows both reads to a borrower for member commands, so another
  # member's loan is `:not_found` at discovery *and* under the lock.
  defp with_locked_item({:item, slug_or_id}, fun) when is_binary(slug_or_id) do
    with {:ok, %Item{} = item} <- ItemGuards.lock_item(slug_or_id), do: fun.(%{item: item})
  end

  defp with_locked_item({:active_item, slug_or_id}, fun) when is_binary(slug_or_id) do
    with {:ok, %Item{} = item} <- ItemGuards.lock_active_item(slug_or_id),
         do: fun.(%{item: item})
  end

  defp with_locked_item({:loan, loan_id, scope}, fun) when is_binary(loan_id) do
    with {:ok, id} <- cast_id(loan_id),
         {:ok, item_id} <- discover_loan_item(id, scope),
         {:ok, %Item{} = item} <- ItemGuards.lock_item(item_id),
         {:ok, %Loan{} = loan} <- lock_loan(id, scope) do
      fun.(%{item: item, loan: loan})
    end
  end

  defp with_locked_item(_subject, _fun), do: {:error, :not_found}

  # Unlocked read used only to learn which container chain to share-lock
  # before the item. Nothing is decided from this row.
  defp peek_item(slug_or_id) when is_binary(slug_or_id) do
    case slug_or_id |> ItemGuards.item_query() |> Repo.one() do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, item}
    end
  end

  defp peek_item(_slug_or_id), do: {:error, :not_found}

  defp lock_preview_container(%Item{container_id: container_id}),
    do: ItemGuards.require_active_container_chain(container_id)

  defp discover_loan_item(id, scope) do
    case id |> loan_query(scope) |> select([l], l.item_id) |> Repo.one() do
      nil -> {:error, :not_found}
      item_id -> {:ok, item_id}
    end
  end

  defp lock_loan(id, scope) do
    case id |> loan_query(scope) |> lock("FOR UPDATE") |> Repo.one() do
      nil -> {:error, :not_found}
      %Loan{} = loan -> {:ok, loan}
    end
  end

  defp loan_query(id, :any), do: from(l in Loan, where: l.id == ^id)

  defp loan_query(id, {:borrower, borrower}),
    do: from(l in Loan, where: l.id == ^id, where: l.borrower_principal_id == ^borrower)

  # ── Availability and interlocks (under the item lock) ───────────

  # The item lock has already serialized this against every other command,
  # so an unavailable item here is a committed fact, not a race.
  defp require_available(%Item{} = item) do
    case ItemProjection.availability(item) do
      %{available?: true} -> :ok
      %{available?: false} -> {:error, :item_unavailable}
    end
  end

  # Only maintenance or archival blocks a handover; `:on_loan` is this very
  # loan holding the item. Archival cannot in fact reach here — it is blocked
  # by an approved loan — so maintenance is the one live cause.
  defp refuse_handover_block(%Item{} = item) do
    if LoanPolicy.handover_blocked?(ItemProjection.availability(item)),
      do: {:error, :maintenance_open},
      else: :ok
  end

  # Locks the item's live loan rows before deciding, so a concurrent approval
  # either committed first (and is seen) or waits behind this transaction.
  defp refuse_active_loan(item_id) do
    from(l in Loan,
      where: l.item_id == ^item_id,
      where: l.status in ^ItemProjection.active_loan_statuses(),
      order_by: [asc: l.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> case do
      [] -> :ok
      _live -> {:error, :loan_active}
    end
  end

  defp refuse_open_maintenance(item_id) do
    case lock_open_period(item_id) do
      {:ok, %MaintenancePeriod{}} -> {:error, :maintenance_open}
      {:error, :no_open_maintenance} -> :ok
    end
  end

  defp lock_open_period(item_id) do
    from(p in MaintenancePeriod,
      where: p.item_id == ^item_id,
      where: is_nil(p.ended_at),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_open_maintenance}
      %MaintenancePeriod{} = period -> {:ok, period}
    end
  end

  defp close_open_period_for_archive(item_id, reason, actor) do
    case lock_open_period(item_id) do
      {:ok, %MaintenancePeriod{} = period} ->
        with {:ok, %MaintenancePeriod{}} <-
               persist(close_period_changeset(period, archive_end_note(reason), actor)),
             do: :ok

      {:error, :no_open_maintenance} ->
        :ok
    end
  end

  defp archive_end_note(nil), do: @default_archive_end_note
  defp archive_end_note(reason), do: "Archived: " <> reason

  # Allocation is exactly-once, so competitors are closed here rather than
  # left pending for a second decision. This is a system rejection, and
  # story 49 gives it no notification.
  defp reject_pending_requests(item_id, actor, note, opts \\ []) do
    from(l in Loan,
      where: l.item_id == ^item_id,
      where: l.status == "requested",
      order_by: [asc: l.id],
      lock: "FOR UPDATE"
    )
    |> exclude_loan(Keyword.get(opts, :except))
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn loan, :ok ->
      case persist(decision_changeset(loan, "rejected", note, actor)) do
        {:ok, _rejected} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp exclude_loan(query, nil), do: query
  defp exclude_loan(query, id), do: where(query, [l], l.id != ^id)

  # ── State and policy ────────────────────────────────────────────

  # An archived item is reported to a member as absent, not as archived: a
  # member has no business learning that an item they cannot see was retired.
  defp require_member_visible(%Item{slug: nil}), do: {:error, :not_found}
  defp require_member_visible(%Item{archived_at: %DateTime{}}), do: {:error, :not_found}
  defp require_member_visible(%Item{}), do: :ok

  defp require_status(%Loan{status: status}, status, _error), do: :ok
  defp require_status(%Loan{}, _required, error), do: {:error, error}

  defp require_editable(%Loan{status: status}) when status in ~w(approved checked_out), do: :ok
  defp require_editable(%Loan{}), do: {:error, :not_editable}

  defp require_within_window(%Loan{} = loan) do
    if LoanPolicy.within_window?(loan, ClubCalendar.today()),
      do: :ok,
      else: {:error, :outside_window}
  end

  defp require_active_category(category_id) do
    case ItemGuards.require_active_category(category_id) do
      {:ok, _id} -> :ok
      {:error, _reason} -> {:error, :archived_category}
    end
  end

  # Revalidate the stored values against the category's live definitions, so
  # a restore cannot resurrect an item that today's schema would reject.
  defp require_retained_values_valid(%Item{} = item) do
    definitions = ItemValues.load_definitions(item.category_id)

    case ItemValues.validate(definitions, stored_values_as_supplied(item.id)) do
      {:ok, _rows} -> :ok
      {:error, errors} -> {:error, {:invalid_values, errors}}
    end
  end

  defp stored_values_as_supplied(item_id) do
    from(v in ItemPropertyValue, where: v.item_id == ^item_id)
    |> Repo.all()
    |> Map.new(&{&1.property_definition_id, supplied_value(&1)})
  end

  defp supplied_value(%ItemPropertyValue{option_id: option_id}) when not is_nil(option_id),
    do: option_id

  defp supplied_value(%ItemPropertyValue{boolean_value: boolean}) when is_boolean(boolean),
    do: boolean

  defp supplied_value(%ItemPropertyValue{decimal_value: decimal}) when not is_nil(decimal),
    do: decimal

  defp supplied_value(%ItemPropertyValue{text_value: text}), do: text

  # ── Dates ───────────────────────────────────────────────────────

  # A member's dates must both be today or later in the club's calendar, with
  # due on or after start. Malformed, missing, and nonsensical are one error:
  # the member has to fix the dates either way.
  defp request_dates(attrs) do
    with {:ok, starts_on} <- cast_date(take(attrs, @start_keys)),
         {:ok, due_on} <- cast_date(take(attrs, @due_keys)),
         :ok <- require_ordered(starts_on, due_on),
         :ok <- require_requestable_start(starts_on) do
      {:ok, starts_on, due_on}
    end
  end

  # Approval defaults to the dates the member asked for. Unlike a request the
  # approved start may be in the past: by decision time the requested start
  # can legitimately have passed, and the record should say what happened.
  defp approval_dates(%Loan{} = loan, attrs) do
    with {:ok, starts_on} <- date_or(take(attrs, @start_keys), loan.requested_start_on),
         {:ok, due_on} <- date_or(take(attrs, @due_keys), loan.requested_due_on),
         :ok <- require_ordered(starts_on, due_on) do
      {:ok, starts_on, due_on}
    end
  end

  # An edit leaves an omitted date alone.
  defp edited_dates(%Loan{} = loan, attrs) do
    current_start = loan.approved_start_on || loan.requested_start_on
    current_due = loan.approved_due_on || loan.requested_due_on

    with {:ok, starts_on} <- date_or(take(attrs, @start_keys), current_start),
         :ok <- require_start_unchanged(loan, starts_on, current_start),
         {:ok, due_on} <- date_or(take(attrs, @due_keys), current_due),
         :ok <- require_ordered(starts_on, due_on),
         :ok <- require_not_before_handover(loan, due_on) do
      {:ok, starts_on, due_on}
    end
  end

  # Restating the same start after checkout is not a change.
  defp require_start_unchanged(%Loan{status: "checked_out"}, starts_on, current_start) do
    if Date.compare(starts_on, current_start) == :eq, do: :ok, else: {:error, :start_immutable}
  end

  defp require_start_unchanged(%Loan{}, _starts_on, _current), do: :ok

  defp require_not_before_handover(%Loan{checked_out_at: %DateTime{} = at}, due_on) do
    if LoanPolicy.due_on_or_after_handover?(due_on, ClubCalendar.on_date(at)),
      do: :ok,
      else: {:error, :invalid_dates}
  end

  defp require_not_before_handover(%Loan{}, _due_on), do: :ok

  defp require_ordered(starts_on, due_on) do
    if LoanPolicy.ordered?(starts_on, due_on), do: :ok, else: {:error, :invalid_dates}
  end

  defp require_requestable_start(starts_on) do
    if LoanPolicy.requestable_start?(starts_on, ClubCalendar.today()),
      do: :ok,
      else: {:error, :invalid_dates}
  end

  defp date_or(nil, fallback), do: {:ok, fallback}
  defp date_or(value, _fallback), do: cast_date(value)

  defp cast_date(%Date{} = date), do: {:ok, date}

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_dates}
    end
  end

  defp cast_date(_value), do: {:error, :invalid_dates}

  # ── Changesets ──────────────────────────────────────────────────

  defp request_changeset(%Item{} = item, borrower, starts_on, due_on, note) do
    Ecto.Changeset.change(%Loan{}, %{
      item_id: item.id,
      borrower_principal_id: borrower,
      status: "requested",
      requested_start_on: starts_on,
      requested_due_on: due_on,
      request_note: note,
      # Captured now so the borrower's history survives archival, and so a
      # later label change does not rewrite what they asked for.
      item_slug_snapshot: item.slug,
      item_label_snapshot: snapshot_label(item)
    })
  end

  defp snapshot_label(%Item{} = item) do
    %Item{label: label, slug: slug} = ItemProjection.project(item)
    label || slug
  end

  defp approval_changeset(%Loan{} = loan, %Item{} = item, starts_on, due_on, note, actor) do
    Ecto.Changeset.change(loan, %{
      status: "approved",
      approved_start_on: starts_on,
      approved_due_on: due_on,
      decided_at: DateTime.utc_now(),
      decided_by_principal_id: actor,
      decision_note: note,
      # Captured at approval because approval is the entitlement to collect
      # (story 15); a later move does not rewrite where the borrower was told
      # to go.
      approved_container_path_snapshot: container_path(item.container_id)
    })
  end

  defp decision_changeset(%Loan{} = loan, target, note, actor) do
    Ecto.Changeset.change(loan, %{
      status: target,
      decided_at: DateTime.utc_now(),
      decided_by_principal_id: actor,
      decision_note: note
    })
  end

  defp checkout_changeset(%Loan{} = loan, actor) do
    Ecto.Changeset.change(loan, %{
      status: "checked_out",
      # The actual handover time is its own fact, kept separate from the
      # approved dates it is checked against.
      checked_out_at: DateTime.utc_now(),
      decided_by_principal_id: actor
    })
  end

  defp return_changeset(%Loan{} = loan, actor) do
    Ecto.Changeset.change(loan, %{
      status: "returned",
      returned_at: DateTime.utc_now(),
      returned_by_principal_id: actor
    })
  end

  defp period_changeset(item_id, reason, actor) do
    Ecto.Changeset.change(%MaintenancePeriod{}, %{
      item_id: item_id,
      started_at: DateTime.utc_now(),
      started_by_principal_id: actor,
      start_reason: reason
    })
  end

  defp close_period_changeset(%MaintenancePeriod{} = period, note, actor) do
    Ecto.Changeset.change(period, %{
      ended_at: DateTime.utc_now(),
      ended_by_principal_id: actor,
      end_note: note
    })
  end

  defp archive_changeset(%Item{} = item, actor) do
    Ecto.Changeset.change(item, %{
      archived_at: DateTime.utc_now(),
      archived_by_principal_id: actor,
      updated_by: actor
    })
  end

  defp restore_changeset(%Item{} = item, actor) do
    Ecto.Changeset.change(item, %{
      archived_at: nil,
      archived_by_principal_id: nil,
      updated_by: actor
    })
  end

  # Maintenance transitions leave the item row's own facts alone but stamp
  # who last touched it.
  defp touch_item(%Item{} = item, actor) do
    with {:ok, %Item{} = touched} <-
           persist(Ecto.Changeset.change(item, %{updated_by: actor})),
         do: item_outcome(touched)
  end

  # ── Persistence and constraint translation ──────────────────────

  # The one write path. Declares every constraint a race or an out-of-seam
  # writer can trip, so the database backstop surfaces as a domain reason
  # rather than a `Postgrex.Error`, and never uses a bang call.
  defp persist(%Ecto.Changeset{data: %schema{}} = changeset) do
    changeset
    |> declare_constraints(schema)
    |> insert_or_update()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = failed} -> {:error, constraint_reason(failed)}
    end
  end

  defp insert_or_update(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset),
    do: Repo.insert(changeset)

  defp insert_or_update(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)

  defp declare_constraints(changeset, schema) do
    changeset
    |> declare_unique_constraints(schema)
    |> declare_actor_foreign_keys(schema)
  end

  defp declare_unique_constraints(changeset, schema) when schema in [Loan, MaintenancePeriod] do
    @unique_constraints
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, schema.__schema__(:source)))
    |> Enum.reduce(changeset, fn name, acc ->
      Ecto.Changeset.unique_constraint(acc, :item_id, name: name)
    end)
  end

  defp declare_unique_constraints(changeset, _schema), do: changeset

  defp declare_actor_foreign_keys(changeset, schema) do
    Enum.reduce(@actor_foreign_keys, changeset, fn
      {^schema, field, name}, acc -> Ecto.Changeset.foreign_key_constraint(acc, field, name: name)
      _other, acc -> acc
    end)
  end

  defp constraint_reason(%Ecto.Changeset{errors: errors}) do
    Enum.find_value(errors, :constraint_violation, fn {_field, {_msg, meta}} ->
      case {Keyword.get(meta, :constraint), Keyword.get(meta, :constraint_name)} do
        {:unique, name} -> Map.get(@unique_constraints, name, :constraint_violation)
        {:foreign, _name} -> :unknown_actor
        _other -> nil
      end
    end)
  end

  # ── Outcomes ────────────────────────────────────────────────────

  defp member_outcome(%Loan{} = loan),
    do: {:ok, {:loan, LoanProjection.member_view(loan, ClubCalendar.today())}}

  defp operator_outcome(%Loan{} = loan),
    do: {:ok, {:loan, LoanProjection.operator_view(loan, ClubCalendar.today())}}

  defp item_outcome(%Item{} = item), do: {:ok, {:item, ItemProjection.project(item)}}

  # ── Container path ──────────────────────────────────────────────

  # The full path from the root, so a borrower reads "Clubhouse › Rack 2"
  # rather than a bare shelf name they cannot locate.
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

  # ── Input normalization ─────────────────────────────────────────

  # Blank text is absence; anything non-textual is rejected rather than
  # silently coerced. The error atom is the caller's, because the loan seams
  # report `:invalid_note` and the item seams `:invalid_text`.
  defp optional_text(nil, _error), do: {:ok, nil}

  defp optional_text(text, error) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      trimmed ->
        if String.length(trimmed) > @max_text_length do
          {:error, error}
        else
          {:ok, trimmed}
        end
    end
  end

  defp optional_text(_other, error), do: {:error, error}

  # An item leaves circulation with a reason or not at all.
  defp require_reason(attrs) do
    case optional_text(take(attrs, @reason_keys), :reason_required) do
      {:ok, nil} -> {:error, :reason_required}
      other -> other
    end
  end

  defp take(attrs, keys) when is_map(attrs) do
    Enum.find_value(keys, fn key ->
      if is_map_key(attrs, key), do: {:present, Map.get(attrs, key)}, else: nil
    end)
    |> case do
      nil -> nil
      {:present, value} -> value
    end
  end

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # ── Transaction ─────────────────────────────────────────────────

  # Each command body returns an outcome to commit or a domain reason to roll
  # back, so the wrapper lives in one place instead of once per command.
  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, outcome} -> outcome
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp restore_attempts do
    :dhc
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:restore_attempts, @restore_attempts)
  end

  defp restore_transact(_actor, _subject, _attrs, remaining) when remaining < 1 do
    {:error, :retry_exhausted}
  end

  defp restore_transact(actor, subject, attrs, remaining) do
    case transact(fn -> run(actor, :reactivate_item, subject, attrs) end) do
      {:error, :container_moved} ->
        restore_transact(actor, subject, attrs, remaining - 1)

      other ->
        other
    end
  end
end
