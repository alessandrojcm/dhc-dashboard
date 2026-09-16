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

  ## Where the work happens

  Since GH-508 the two commands here are a **facade**: each is one
  `Dhc.Inventory.AvailabilityCommands.execute/2` call as a `{:member, id}`
  actor. That boundary owns the transaction, locks the item `FOR UPDATE`
  before the loan (the reverse order deadlocks against approval), re-reads
  the loan under it, derives availability, applies the club-calendar date
  policy, translates the pending-request index into `:duplicate_request`, and
  builds the member projection. Nothing about a transition is decided here.
  The reads — own history and own loan — stay in this module.

  ## Notifications

  None, on purpose. Operators should learn about new requests and member
  cancellations (ALE-275), but the keyed, idempotent notification seam is
  ALE-287; wiring the non-keyed creation path here would create the
  duplicate-notification problem it exists to prevent. The transitions this
  slice writes are durable rows, so notifications can attach to them later
  without reshaping the commands.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.AvailabilityCommands
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanProjection
  alias Dhc.Repo

  @allowed_limits [10, 25, 50, 100]
  @default_limit 25
  @allowed_directions ~w(asc desc)

  # A loan's creation time is immutable, which makes it the one ordering key
  # no transition can change underneath a cursor.
  @sort_specs %{"createdAt" => %{field: :created_at, type: :utc_datetime_usec}}

  @open_statuses ~w(requested approved checked_out)
  @closed_statuses ~w(rejected cancelled returned)

  @typedoc """
  One loan as its borrower sees it — `Dhc.Inventory.LoanProjection.member_loan/0`.

  `item_*` are the retained snapshot (slug and label captured at request
  time), not a live item read, so history stays readable after archival.
  `container_path` is present only once the loan is approved — that is the
  one flow entitled to the item's location (story 15).
  """
  @type member_loan :: LoanProjection.member_loan()

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
      when is_binary(slug_or_id) and is_map(attrs) and is_binary(borrower_id),
      do: command(borrower_id, {:request_loan, slug_or_id, attrs})

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
      when is_binary(loan_id) and is_map(attrs) and is_binary(borrower_id),
      do: command(borrower_id, {:cancel_request, loan_id, attrs})

  defp command(borrower_id, command) do
    case AvailabilityCommands.execute({:member, borrower_id}, command) do
      {:ok, {:loan, view}} -> {:ok, view}
      {:error, reason} -> {:error, reason}
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

  # Every row goes through the shared projection so a list row, a detail
  # read, and a command outcome cannot disagree; `today` is resolved once per
  # page so every row is judged against the same club-calendar day.
  defp member_views([]), do: []

  defp member_views(loans) do
    today = ClubCalendar.today()
    Enum.map(loans, &LoanProjection.member_view(&1, today))
  end

  defp member_view(%Loan{} = loan), do: LoanProjection.member_view(loan, ClubCalendar.today())

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
end
