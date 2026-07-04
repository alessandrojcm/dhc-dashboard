defmodule Dhc.Waitlist do
  @moduledoc """
  Waitlist context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Repo

  @waitlist_open_key "waitlist_open"
  @age_years_sql "EXTRACT(YEAR FROM AGE(CURRENT_DATE, ?))::int"
  @allowed_limits [10, 25, 50, 100]
  @allowed_statuses ~w(waiting invited paid deferred cancelled completed no_reply joined)
  @allowed_sort_fields ~w(position fullName status age initialRegistrationDate lastContacted lastStatusChange)
  @allowed_directions ~w(asc desc)
  @entry_sort_specs %{
    "position" => %{field: :position},
    "fullName" => %{field: :full_name_sort},
    "status" => %{field: :status},
    "age" => %{field: :age},
    "initialRegistrationDate" => %{
      field: :initial_registration_date,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    },
    "lastContacted" => %{
      field: :last_contacted_sort,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    },
    "lastStatusChange" => %{
      field: :last_status_change,
      type: :utc_datetime,
      encode: &DateTime.to_iso8601/1
    }
  }

  @doc """
  Returns the public waitlist status.

  Missing or malformed settings are treated as closed so the public endpoint
  always returns a safe domain-shaped status instead of exposing settings rows.
  """
  @spec status() :: %{is_open: boolean()}
  def status do
    %{is_open: open?()}
  end

  @doc """
  Returns domain-shaped waitlist analytics for the dashboard.

  The queries intentionally read the `waitlist` and `user_profiles` storage
  tables directly inside Phoenix, rather than exposing `waitlist_management_view`
  or `user_profiles` as API resources.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution()
    }
  end

  @doc """
  Returns cursor-paginated, domain-shaped waitlist entries for the dashboard.

  Cursor payloads bind to the query semantics (limit, search, status, sort and
  direction), so stale cursors from a different table state return an explicit
  `{:error, :bad_cursor}` instead of silently serving the wrong page.
  """
  @spec entries(map()) :: {:ok, map()} | {:error, atom()}
  def entries(params \\ %{}) do
    with {:ok, opts} <- parse_entry_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &entry_cursor_context/1) do
      total_count = entries_total_count(opts)
      rows = entries_rows(opts, cursor)

      page =
        CursorPagination.page(rows, opts, cursor, &entry_cursor_context/1, &entry_cursor_value/2)

      {:ok,
       %{
         entries: page.visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: page.next_cursor,
         previous_cursor: page.previous_cursor
       }}
    end
  end

  @spec open?() :: boolean()
  def open? do
    from(s in "settings",
      where: field(s, :key) == ^@waitlist_open_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> case do
      "true" -> true
      _ -> false
    end
  end

  defp total_count do
    base_analytics_query()
    |> select([w, _p], count(w.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    base_analytics_query()
    |> select(
      [_w, p],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    base_analytics_query()
    |> where([_w, p], not is_nil(p.gender))
    |> group_by([_w, p], p.gender)
    |> order_by([_w, p], asc: p.gender)
    |> select([_w, p], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    base_analytics_query()
    |> group_by(
      [_w, p],
      fragment(@age_years_sql, p.date_of_birth)
    )
    |> order_by(
      [_w, p],
      asc: fragment(@age_years_sql, p.date_of_birth)
    )
    |> select([_w, p], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp base_analytics_query do
    from w in WaitlistEntry,
      join: p in UserProfile,
      on: p.waitlist_id == w.id,
      where:
        w.status != "joined" and p.is_active == false and is_nil(p.supabase_user_id) and
          not is_nil(p.date_of_birth)
  end

  defp parse_entry_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "position")
    direction = Map.get(params, "direction", "asc")
    status = blank_to_nil(Map.get(params, "status"))
    q = blank_to_nil(Map.get(params, "q"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      not is_nil(status) and status not in @allowed_statuses ->
        {:error, :invalid_status}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
           status: status,
           q: q,
           cursor: blank_to_nil(Map.get(params, "cursor"))
         }}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp entry_cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "status" => opts.status,
      "q" => opts.q
    }
  end

  defp entries_total_count(opts) do
    opts
    |> base_entries_query()
    |> select([w, _p, _wg], count(w.id))
    |> Repo.one()
  end

  defp entries_rows(opts, cursor) do
    query_direction = CursorPagination.query_direction(opts, cursor)

    opts
    |> positioned_entries_query()
    |> CursorPagination.apply_cursor(cursor, opts, @entry_sort_specs)
    |> CursorPagination.apply_order(entry_order_field(opts.sort), query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> CursorPagination.maybe_reverse(cursor)
  end

  defp base_entries_query(opts) do
    base_query =
      from w in WaitlistEntry,
        join: p in UserProfile,
        on: p.waitlist_id == w.id,
        left_join: wg in "waitlist_guardians",
        on: field(wg, :profile_id) == p.id,
        where: p.is_active == false and is_nil(p.supabase_user_id)

    base_query
    |> filter_entries_status(opts.status)
    |> filter_entries_search(opts.q)
  end

  defp filter_entries_status(query, nil), do: where(query, [w, _p, _wg], w.status != "joined")
  defp filter_entries_status(query, status), do: where(query, [w, _p, _wg], w.status == ^status)

  defp filter_entries_search(query, nil), do: query

  defp filter_entries_search(query, q) do
    where(
      query,
      [_w, p, _wg],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(p, :search_text), ^q)
    )
  end

  defp positioned_entries_query(opts) do
    opts
    |> base_entries_query()
    |> select([w, p, wg], %{
      id: w.id,
      position:
        fragment(
          "row_number() OVER (ORDER BY ? ASC, ? ASC)::int",
          w.initial_registration_date,
          w.id
        ),
      full_name: fragment("concat(?, ' ', ?)", p.first_name, p.last_name),
      full_name_sort: fragment("lower(concat(?, ' ', ?))", p.first_name, p.last_name),
      email: w.email,
      phone_number: p.phone_number,
      status: type(w.status, :string),
      age: fragment(@age_years_sql, p.date_of_birth),
      initial_registration_date: w.initial_registration_date,
      last_contacted: w.last_contacted,
      last_contacted_sort:
        fragment("coalesce(?, '1970-01-01 00:00:00Z'::timestamptz)", w.last_contacted),
      medical_conditions: p.medical_conditions,
      admin_notes: w.admin_notes,
      social_media_consent: type(p.social_media_consent, :string),
      guardian_first_name: field(wg, :first_name),
      guardian_last_name: field(wg, :last_name),
      guardian_phone_number: field(wg, :phone_number),
      insurance_form_submitted: fragment("false"),
      last_status_change: w.last_status_change
    })
    |> subquery()
  end

  defp entry_order_field("position"), do: :position
  defp entry_order_field("fullName"), do: :full_name_sort
  defp entry_order_field("status"), do: :status
  defp entry_order_field("age"), do: :age
  defp entry_order_field("initialRegistrationDate"), do: :initial_registration_date
  defp entry_order_field("lastContacted"), do: :last_contacted_sort
  defp entry_order_field("lastStatusChange"), do: :last_status_change

  defp entry_cursor_value(row, %{sort: "fullName"}), do: String.downcase(row.full_name)

  defp entry_cursor_value(row, opts) do
    spec = Map.fetch!(@entry_sort_specs, opts.sort)
    value = Map.fetch!(row, spec.field)

    if encode = Map.get(spec, :encode), do: encode.(value), else: value
  end
end
