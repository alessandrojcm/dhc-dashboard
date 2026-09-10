defmodule Dhc.Inventory.MemberLoans do
  @moduledoc """
  ALE-285: the member half of the loan lifecycle behind `Dhc.Inventory`.

  A member may request an available item for themselves, cancel their own
  loan until checkout, and read their own complete history. The operator
  half — approve, reject, check out, return, edit approved dates, and the
  shared queue — is ALE-286; this slice deliberately creates only
  `requested` rows and only ever moves one of its own rows to `cancelled`.

  ## What a member may do, and why each rule exists

    * **Request for themselves only.** There is no borrower parameter: the
      borrower is the caller's principal. A quartermaster requesting an item
      does so as a member under exactly these rules (ALE-273).
    * **Both dates today or later, due on or after start.** Dates are
      calendar days in `Europe/Dublin` (`Dhc.Inventory.ClubCalendar`), so a
      request made after midnight Dublin time is not rejected for being
      "yesterday" in UTC.
    * **At most one pending request per item per member**, backed by the
      partial unique index
      `inventory_loans_one_pending_request_per_item_borrower`. A member may
      hold requests on any number of *different* items — kitting out fully
      is normal, spamming one item is not.
    * **Competing requests coexist.** A pending request is not a
      reservation, a queue, or an entitlement (story 34), which is exactly
      why `Dhc.Inventory.ItemProjection` does not treat `requested` as an
      availability input. Approval is the single fair decision point.
    * **Requestable means available.** Not archived, not in maintenance, and
      not held by an approved or checked-out loan. The reason a member is
      shown for a refusal stays generic (`:item_unavailable`) — never a
      borrower, a date, or a maintenance note.
    * **Cancel until checkout.** A member cancels their own `requested` or
      `approved` loan; after checkout they physically hold the item, so
      release is the operator's `return` command (ALE-286).
    * **Complete history.** Rejections and cancellations included, with
      their notes, and item snapshots so an archived item does not rot the
      record (story 56).

  ## Serialization

  A request locks the item `FOR UPDATE` first, so it queues behind every
  other availability-changing command (approval, maintenance start,
  archive). A request that loses a race sees a domain conflict rather than
  an exception, and the pending-request index is translated the same way, so
  a second concurrent request from the same member cannot surface as a
  `Postgrex.Error`.

  ## Notifications

  None yet, on purpose. Operators should learn about new requests and member
  cancellations (ALE-275), but the keyed, idempotent notification seam is
  ALE-287, which the spec makes a hard prerequisite for exposed loan
  commands. Wiring the current non-keyed creation path here would create the
  duplicate-notification problem ALE-287 exists to prevent. The transitions
  this slice writes are durable rows, so ALE-287 can attach notifications to
  them without reshaping the commands.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.Loan
  alias Dhc.Repo

  @max_note_length 1000

  @allowed_limits [10, 25, 50, 100]
  @default_limit 25
  @allowed_directions ~w(asc desc)

  # A loan's creation time is immutable, which makes it the one ordering key
  # no transition can change underneath a cursor.
  @sort_specs %{"createdAt" => %{field: :created_at, type: :utc_datetime_usec}}

  # Statuses a member may still walk away from. After checkout the member
  # holds the item, so only an operator return closes the loan.
  @member_cancellable ~w(requested approved)

  @open_statuses ~w(requested approved checked_out)
  @closed_statuses ~w(rejected cancelled returned)

  @typedoc """
  One loan as its borrower sees it.

  `item` is the retained snapshot (slug and label captured at request time),
  not a live item read, so history stays readable after archival.
  `containerPath` is present only once the loan is approved — that is the
  one flow entitled to the item's location (story 15).
  """
  @type member_loan :: %{
          id: String.t(),
          item_id: String.t(),
          status: String.t(),
          overdue?: boolean(),
          requested_start_on: Date.t(),
          requested_due_on: Date.t(),
          approved_start_on: Date.t() | nil,
          approved_due_on: Date.t() | nil,
          checked_out_at: DateTime.t() | nil,
          returned_at: DateTime.t() | nil,
          request_note: String.t() | nil,
          decision_note: String.t() | nil,
          item_slug: String.t(),
          item_label: String.t(),
          container_path: String.t() | nil,
          created_at: DateTime.t()
        }

  @type request_error ::
          :not_found
          | :item_unavailable
          | :invalid_dates
          | :duplicate_request
          | :invalid_note

  @type page :: %{
          loans: [member_loan()],
          total_count: non_neg_integer(),
          limit: pos_integer(),
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil
        }

  @type list_error :: :invalid_limit | :invalid_direction | :invalid_status | :bad_cursor

  # ── Request ─────────────────────────────────────────────────────

  @doc """
  Request one available item for the calling member.

  `attrs` carries `startsOn`, `dueOn`, and an optional `note`. The borrower
  is `borrower_id`; a member can never request on someone else's behalf.
  """
  @spec request_loan(String.t(), map(), String.t()) ::
          {:ok, member_loan()} | {:error, request_error()}
  def request_loan(slug_or_id, attrs, borrower_id)
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(borrower_id) do
    Repo.transaction(fn -> locked_request(slug_or_id, attrs, borrower_id) end) |> unwrap()
  end

  defp locked_request(slug_or_id, attrs, borrower_id) do
    with {:ok, %Item{} = item} <- lock_requestable_item(slug_or_id),
         {:ok, starts_on, due_on} <- parse_dates(attrs),
         {:ok, note} <- optional_note(take(attrs, ["note", :note])),
         :ok <- require_available(item),
         {:ok, %Loan{} = loan} <- insert_request(item, borrower_id, starts_on, due_on, note) do
      member_view(loan)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # An archived item is reported as absent, not as archived: a member has no
  # business learning that an item they cannot see was retired.
  defp lock_requestable_item(slug_or_id) do
    case ItemGuards.lock_item(slug_or_id) do
      {:ok, %Item{slug: nil}} -> {:error, :not_found}
      {:ok, %Item{archived_at: at}} when not is_nil(at) -> {:error, :not_found}
      other -> other
    end
  end

  # Availability comes from the shared projection, so "requestable" can never
  # drift from what the catalog showed the member — and the refusal reason
  # stays generic whatever made the item unavailable.
  defp require_available(%Item{} = item) do
    case ItemProjection.availability(item) do
      %{available?: true} -> :ok
      %{available?: false} -> {:error, :item_unavailable}
    end
  end

  # The item lock serializes request-against-request within this seam, so the
  # partial unique index is the backstop for anything writing outside it.
  # Translate it rather than letting Postgrex raise (`Repo.insert` + `case`,
  # never `insert!`): a race must be a domain conflict, not a 500.
  defp insert_request(%Item{} = item, borrower_id, starts_on, due_on, note) do
    %Loan{}
    |> Ecto.Changeset.change(%{
      item_id: item.id,
      borrower_principal_id: borrower_id,
      status: "requested",
      requested_start_on: starts_on,
      requested_due_on: due_on,
      request_note: note,
      # Captured now so the borrower's history survives archival, and so a
      # later label change does not rewrite what they asked for.
      item_slug_snapshot: item.slug,
      item_label_snapshot: snapshot_label(item)
    })
    |> Ecto.Changeset.unique_constraint(:item_id,
      name: :inventory_loans_one_pending_request_per_item_borrower
    )
    |> Repo.insert()
    |> case do
      {:ok, %Loan{} = loan} -> {:ok, loan}
      {:error, %Ecto.Changeset{}} -> {:error, :duplicate_request}
    end
  end

  defp snapshot_label(%Item{} = item) do
    %Item{label: label, slug: slug} = ItemProjection.project(item)
    label || slug
  end

  # ── Cancel ──────────────────────────────────────────────────────

  @doc """
  Cancel one of the calling member's own loans, before checkout.

  Cancelling a loan that is already cancelled is a no-op, so a repeated tap
  on a mobile button is not an error. A loan belonging to another member is
  reported as `:not_found`: whether someone else's loan exists is not a
  member-visible fact.
  """
  @spec cancel_loan(String.t(), map(), String.t()) ::
          {:ok, member_loan()}
          | {:error, :not_found}
          | {:error, :not_cancellable}
          | {:error, :invalid_note}
  def cancel_loan(loan_id, attrs, borrower_id)
      when is_binary(loan_id) and is_map(attrs) and is_binary(borrower_id) do
    Repo.transaction(fn -> locked_cancel(loan_id, attrs, borrower_id) end) |> unwrap()
  end

  defp locked_cancel(loan_id, attrs, borrower_id) do
    with {:ok, %Loan{} = loan} <- lock_own_loan(loan_id, borrower_id),
         {:ok, note} <- optional_note(take(attrs, ["note", :note])),
         {:ok, %Loan{} = loan} <- apply_cancellation(loan, note, borrower_id) do
      member_view(loan)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Cancellation releases the item, so it is an availability-changing command
  # and must serialize on the item like every other one — see
  # `Dhc.Inventory.OperatorItemLifecycle`, where each command takes the item
  # `FOR UPDATE` first.
  #
  # The lock **order** matters as much as the lock: request (and every
  # operator command) locks the item before the loan, so cancelling in the
  # opposite order would let a cancel holding the loan row wait on the item
  # while an approval holding the item waits on the loan — a deadlock rather
  # than a queue. Locking the item first puts this command in the same queue
  # as the ALE-286 approval and checkout commands.
  #
  # The item id is read unlocked first purely to know *which* item to lock;
  # ownership and status are then re-resolved under the item lock, so nothing
  # is decided from the unlocked read.
  defp lock_own_loan(loan_id, borrower_id) do
    with {:ok, id} <- cast_id(loan_id),
         {:ok, item_id} <- own_loan_item_id(id, borrower_id),
         {:ok, _item} <- ItemGuards.lock_item(item_id) do
      fetch_own_loan(id, borrower_id)
    end
  end

  defp own_loan_item_id(id, borrower_id) do
    query =
      from(l in Loan,
        where: l.id == ^id,
        where: l.borrower_principal_id == ^borrower_id,
        select: l.item_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      item_id -> {:ok, item_id}
    end
  end

  defp apply_cancellation(%Loan{status: "cancelled"} = loan, _note, _borrower_id), do: {:ok, loan}

  defp apply_cancellation(%Loan{status: status} = loan, note, borrower_id)
       when status in @member_cancellable do
    {:ok,
     loan
     |> Ecto.Changeset.change(%{
       status: "cancelled",
       decided_at: DateTime.utc_now(),
       decided_by_principal_id: borrower_id,
       decision_note: note
     })
     |> Repo.update!()}
  end

  defp apply_cancellation(%Loan{}, _note, _borrower_id), do: {:error, :not_cancellable}

  # Re-read under the item lock, itself `FOR UPDATE`, so the status the
  # cancellation decision uses cannot change between the check and the write.
  defp fetch_own_loan(id, borrower_id) do
    query =
      from(l in Loan,
        where: l.id == ^id,
        where: l.borrower_principal_id == ^borrower_id,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Loan{} = loan -> {:ok, loan}
    end
  end

  # ── Own history ─────────────────────────────────────────────────

  @doc """
  One member's loans as a cursor-paginated page, newest first.

  Complete by design (story 42): rejected and cancelled requests stay
  visible with their notes. `status: "open"` narrows to the obligations a
  member can still act on; `"closed"` to the finished record.

  Paginated because a member's history only ever grows — every rejected and
  cancelled request is retained forever — so an unbounded list would degrade
  quietly for the club's longest-standing members. Ordering is on
  `created_at` with an `id` tie-break: a loan's creation time never changes,
  and the tie-break keeps bulk-created rows from sharing a boundary.
  """
  @spec list_own_loans(String.t(), map()) :: {:ok, page()} | {:error, list_error()}
  def list_own_loans(borrower_id, params \\ %{}) when is_binary(borrower_id) do
    with {:ok, opts} <- parse_list_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &cursor_context/1) do
      {:ok, own_loan_page(borrower_id, opts, cursor)}
    end
  end

  @doc """
  One of the calling member's own loans.
  """
  @spec get_own_loan(String.t(), String.t()) :: {:ok, member_loan()} | {:error, :not_found}
  def get_own_loan(loan_id, borrower_id) when is_binary(loan_id) and is_binary(borrower_id) do
    with {:ok, id} <- cast_id(loan_id),
         %Loan{} = loan <-
           Repo.one(
             from(l in Loan,
               where: l.id == ^id,
               where: l.borrower_principal_id == ^borrower_id
             )
           ) do
      {:ok, member_view(loan)}
    else
      _absent -> {:error, :not_found}
    end
  end

  defp own_loan_page(borrower_id, opts, cursor) do
    rows =
      borrower_id
      |> own_loans_query(opts.statuses)
      |> CursorPagination.apply_cursor(cursor, opts, @sort_specs)
      |> CursorPagination.apply_order(
        :created_at,
        CursorPagination.query_direction(opts, cursor)
      )
      |> limit(^(opts.limit + 1))
      |> Repo.all()
      |> CursorPagination.maybe_reverse(cursor)

    page = CursorPagination.page(rows, opts, cursor, &cursor_context/1, &cursor_value/2)

    %{
      loans: member_views(page.visible_rows),
      total_count: own_loans_count(borrower_id, opts.statuses),
      limit: opts.limit,
      next_cursor: page.next_cursor,
      previous_cursor: page.previous_cursor
    }
  end

  defp own_loans_count(borrower_id, statuses) do
    borrower_id
    |> own_loans_query(statuses)
    |> select([l], count(l.id))
    |> Repo.one()
  end

  # The borrower predicate is part of the query itself rather than a filter
  # applied by callers, so no caller can list another member's loans.
  defp own_loans_query(borrower_id, statuses) do
    from(l in Loan, where: l.borrower_principal_id == ^borrower_id)
    |> filter_statuses(statuses)
  end

  defp filter_statuses(query, nil), do: query
  defp filter_statuses(query, statuses), do: where(query, [l], l.status in ^statuses)

  defp parse_list_options(params) when is_list(params), do: parse_list_options(Map.new(params))

  defp parse_list_options(params) do
    with {:ok, limit} <- parse_limit(take(params, ["limit", :limit])),
         {:ok, direction} <- parse_direction(take(params, ["direction", :direction])),
         {:ok, statuses} <- parse_status_filter(take(params, ["status", :status])) do
      {:ok,
       %{
         limit: limit,
         sort: "createdAt",
         direction: direction,
         statuses: statuses,
         status: normalize_status(take(params, ["status", :status])),
         cursor: blank_to_nil(take(params, ["cursor", :cursor]))
       }}
    end
  end

  # Newest-first is the default a history is read in, so `direction` defaults
  # to `desc` here rather than to the catalog's ascending slug order.
  defp parse_direction(nil), do: {:ok, "desc"}
  defp parse_direction(""), do: {:ok, "desc"}

  defp parse_direction(direction) when is_binary(direction) do
    if direction in @allowed_directions,
      do: {:ok, direction},
      else: {:error, :invalid_direction}
  end

  defp parse_direction(_direction), do: {:error, :invalid_direction}

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(""), do: {:ok, @default_limit}
  defp parse_limit(limit) when limit in @allowed_limits, do: {:ok, limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> parse_limit(parsed)
      _other -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_limit), do: {:error, :invalid_limit}

  defp parse_status_filter(nil), do: {:ok, nil}
  defp parse_status_filter(""), do: {:ok, nil}
  defp parse_status_filter("all"), do: {:ok, nil}
  defp parse_status_filter("open"), do: {:ok, @open_statuses}
  defp parse_status_filter("closed"), do: {:ok, @closed_statuses}
  defp parse_status_filter(_other), do: {:error, :invalid_status}

  # The cursor binds to the *requested* filter word, not the expanded status
  # list, so it stays stable if the membership of `open`/`closed` is ever
  # revised.
  defp normalize_status(status) when status in [nil, "", "all"], do: "all"
  defp normalize_status(status) when is_binary(status), do: status

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "status" => opts.status
    }
  end

  defp cursor_value(row, _opts), do: DateTime.to_iso8601(row.created_at)

  # ── Member view ─────────────────────────────────────────────────

  defp member_views([]), do: []

  defp member_views(loans) do
    today = ClubCalendar.today()
    Enum.map(loans, &member_view(&1, today))
  end

  defp member_view(%Loan{} = loan), do: member_view(loan, ClubCalendar.today())

  defp member_view(%Loan{} = loan, today) do
    %{
      id: loan.id,
      item_id: loan.item_id,
      status: loan.status,
      overdue?: overdue?(loan, today),
      requested_start_on: loan.requested_start_on,
      requested_due_on: loan.requested_due_on,
      approved_start_on: loan.approved_start_on,
      approved_due_on: loan.approved_due_on,
      checked_out_at: loan.checked_out_at,
      returned_at: loan.returned_at,
      request_note: loan.request_note,
      decision_note: loan.decision_note,
      item_slug: loan.item_slug_snapshot,
      item_label: loan.item_label_snapshot,
      container_path: container_path(loan),
      created_at: loan.created_at
    }
  end

  # Overdue is derived, never a stored state (story 41): a checked-out loan
  # past its approved due date is late, and moving the due date forward makes
  # it not late again with no transition to undo.
  defp overdue?(%Loan{status: "checked_out", approved_due_on: %Date{} = due_on}, today),
    do: Date.compare(today, due_on) == :gt

  defp overdue?(%Loan{}, _today), do: false

  # The container path is the borrower's collection entitlement, and only
  # once the loan is approved (story 15). Before approval there is no
  # entitlement, so the location stays hidden even though the row may
  # already carry a snapshot.
  defp container_path(%Loan{status: status, approved_container_path_snapshot: path})
       when status in ~w(approved checked_out returned),
       do: path

  defp container_path(%Loan{}), do: nil

  # ── Dates ───────────────────────────────────────────────────────

  # Both dates must be today or later in the club's calendar, with due on or
  # after start. A malformed or missing date is the same domain error as a
  # nonsensical one: the member has to fix the dates either way.
  defp parse_dates(attrs) do
    with {:ok, starts_on} <-
           cast_date(take(attrs, ["startsOn", "starts_on", :startsOn, :starts_on])),
         {:ok, due_on} <- cast_date(take(attrs, ["dueOn", "due_on", :dueOn, :due_on])),
         :ok <- require_ordered(starts_on, due_on),
         :ok <- require_not_past(starts_on) do
      {:ok, starts_on, due_on}
    end
  end

  defp cast_date(%Date{} = date), do: {:ok, date}

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_dates}
    end
  end

  defp cast_date(_value), do: {:error, :invalid_dates}

  defp require_ordered(starts_on, due_on) do
    if Date.compare(due_on, starts_on) == :lt, do: {:error, :invalid_dates}, else: :ok
  end

  defp require_not_past(starts_on) do
    if Date.compare(starts_on, ClubCalendar.today()) == :lt,
      do: {:error, :invalid_dates},
      else: :ok
  end

  # ── Notes ───────────────────────────────────────────────────────

  # Blank is absence, matching the item seam's notes rule; anything
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

  defp unwrap({:ok, view}), do: {:ok, view}
  defp unwrap({:error, reason}), do: {:error, reason}
end
