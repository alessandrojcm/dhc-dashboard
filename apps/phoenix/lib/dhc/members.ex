defmodule Dhc.Members do
  @moduledoc """
  Members context functions used by Phoenix API controllers.

  This is the context shell introduced by the Members read migration
  (issue #123). Later slices (member list, analytics) extend this module.
  """

  import Ecto.Query

  alias Dhc.Auth.AuthUser
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @insurance_form_link_key "hema_insurance_form_link"
  # Mirrors `member_management_view.age` (`EXTRACT(year FROM AGE(date_of_birth))`)
  # so analytics match the prior client-side aggregates exactly.
  @age_years_sql "EXTRACT(year FROM AGE(?))::int"
  @allowed_limits [10, 25, 50, 100]
  @allowed_sort_fields ~w(firstName lastName email phoneNumber age membershipStartDate lastPaymentDate subscriptionPausedUntil isActive)
  @allowed_directions ~w(asc desc)
  @allowed_membership_statuses ~w(active inactive paused)

  @doc """
  Returns the member insurance form link.

  Reads the `hema_insurance_form_link` settings row and exposes it as a
  domain-shaped value, not a generic settings proxy. A missing row or an
  empty/whitespace-only value is reported as `nil` so callers can render
  "not configured" without knowing the storage shape.

  RBAC is enforced at the controller layer (any authenticated user), mirroring
  the `settings` SELECT RLS policy (`USING (true)` for authenticated).
  """
  @spec insurance_form() :: %{link: String.t() | nil}
  def insurance_form do
    %{link: insurance_form_link()}
  end

  @doc """
  Returns domain-shaped members analytics for the dashboard.

  Computed server-side over active members — `member_profiles` joined to
  `user_profiles` where `is_active = true` — replacing the five browser-side
  PostgREST aggregates over `member_management_view`. The `preferred_weapon[]`
  array is unnested and counted in SQL so the browser no longer downloads
  every active member's weapon array to count it in JavaScript.

  - `total_count` counts every active member (including those without a known
    date of birth).
  - `average_age` averages ages of active members with a known date of birth,
    coerced to `0.0` when none have one.
  - `gender_distribution` and `age_distribution` exclude members whose
    `gender`/`date_of_birth` is `nil` (no "Unknown"/null bucket).
  - `weapon_distribution` returns raw enum strings; the UI prettifies them.

  RBAC is enforced at the controller layer (broad committee roles), mirroring
  the `user_profiles` SELECT RLS policy.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}],
          weapon_distribution: [%{weapon: String.t(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution(),
      weapon_distribution: weapon_distribution()
    }
  end

  @doc """
  Returns cursor-paginated, domain-shaped members for the dashboard table.

  Replaces the browser-side PostgREST read over `member_management_view`.
  `membershipStatus` is computed server-side, reproducing the legacy view's
  CASE: `inactive` when `is_active = false`; `paused` when
  `subscription_paused_until > now()`; otherwise `active`. Distinct from the
  `is_active` flag — a paused member has `is_active: true, membership_status:
  "paused"`.

  Cursor payloads bind to the query semantics (limit, search, status filter,
  sort and direction), so stale cursors from a different table state return an
  explicit `{:error, :bad_cursor}` instead of silently serving the wrong page.
  """
  @spec list_members(map()) :: {:ok, map()} | {:error, atom()}
  def list_members(params \\ %{}) do
    with {:ok, opts} <- parse_list_options(params),
         {:ok, cursor} <- parse_cursor(opts) do
      total_count = list_total_count(opts)
      rows = list_rows(opts, cursor)
      visible_rows = Enum.take(rows, opts.limit)

      {:ok,
       %{
         members: visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: next_cursor(visible_rows, rows, opts, cursor),
         previous_cursor: previous_cursor(visible_rows, rows, opts, cursor)
       }}
    end
  end

  @spec insurance_form_link() :: String.t() | nil
  defp insurance_form_link do
    from(s in "settings",
      where: field(s, :key) == ^@insurance_form_link_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> normalize_link()
  end

  defp normalize_link(nil), do: nil

  defp normalize_link(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Analytics ────────────────────────────────────────────────────────

  defp total_count do
    active_members_base()
    |> select([p, _m], count(p.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    # `avg/4` ignores NULL ages (members without a date_of_birth); coalesce
    # guards the empty set so callers get 0.0 instead of nil.
    active_members_base()
    |> select(
      [p, _m],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.gender))
    |> group_by([p, _m], p.gender)
    |> order_by([p, _m], asc: p.gender)
    |> select([p, _m], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.date_of_birth))
    |> group_by([p, _m], fragment(@age_years_sql, p.date_of_birth))
    |> order_by([p, _m], asc: fragment(@age_years_sql, p.date_of_birth))
    |> select([p, _m], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp weapon_distribution do
    # Unnest the `preferred_weapon[]` array in SQL and count per weapon so the
    # browser no longer downloads every active member's weapon array. Members
    # with an empty array contribute no rows (INNER LATERAL drops them —
    # correct, they own no weapon).
    #
    # The fragment is a `SELECT weapon FROM unnest(?) AS t(weapon)` subquery so
    # the unnested value gets a real column name Ecto can address as `w.weapon`
    # (Ecto rejects selecting the whole fragment binding `w`). `inner_lateral`
    # lets the subquery reference the correlated `m.preferred_weapon` column.
    # Raw enum strings are returned; the UI prettifies them for display.
    active_members_base()
    |> join(
      :inner_lateral,
      [p, m],
      w in fragment("SELECT weapon FROM unnest(?) AS t(weapon)", m.preferred_weapon),
      on: true
    )
    |> group_by([..., w], w.weapon)
    |> order_by([..., w], asc: w.weapon)
    |> select([..., w], %{weapon: w.weapon, value: count()})
    |> Repo.all()
  end

  defp active_members_base do
    from p in UserProfile,
      join: m in "member_profiles",
      on: field(m, :user_profile_id) == p.id,
      where: p.is_active == true
  end

  # ── Members list (cursor-paginated) ─────────────────────────────────
  #
  # Mirrors the Waitlist entries cursor pattern: a positioned subquery
  # selects the DTO fields plus per-sort helper columns, the outer query
  # applies the cursor comparator (with `id` tiebreaker) and the ORDER BY,
  # and `limit + 1` detects whether another page exists.
  #
  # The base join order is `m` (member_profiles) → `p` (user_profiles) →
  # `u` (auth.users, for email) → `wg` (waitlist_guardians, left join), so
  # the first two bindings `[m, p]` are stable for the membership-status
  # `dynamic` filter clauses.

  @epoch_datetime ~U[1970-01-01 00:00:00Z]

  defp parse_list_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "lastName")
    direction = Map.get(params, "direction", "asc")
    membership_status_raw = blank_to_nil(Map.get(params, "membershipStatus"))
    q = blank_to_nil(Map.get(params, "q"))

    membership_status =
      if membership_status_raw do
        membership_status_raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      else
        nil
      end

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      membership_status != nil and
          not Enum.all?(membership_status, &(&1 in @allowed_membership_statuses)) ->
        {:error, :invalid_membership_status}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
           membership_status: membership_status,
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

  defp parse_cursor(%{cursor: nil}), do: {:ok, nil}

  defp parse_cursor(opts) do
    with {:ok, json} <- Base.url_decode64(opts.cursor, padding: false),
         {:ok, cursor} <- Jason.decode(json),
         true <- cursor_matches?(cursor, opts),
         true <- cursor["pageDirection"] in ["next", "previous"],
         true <- is_binary(cursor["id"]),
         true <- Map.has_key?(cursor, "value") do
      {:ok, cursor}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp cursor_matches?(cursor, opts) do
    cursor["limit"] == opts.limit and cursor["sort"] == opts.sort and
      cursor["direction"] == opts.direction and
      cursor["membershipStatus"] == opts.membership_status and
      cursor["q"] == opts.q
  end

  defp list_total_count(opts) do
    opts
    |> base_list_query()
    |> select([m, _p], count(m.id))
    |> Repo.one()
  end

  defp list_rows(opts, cursor) do
    query_direction =
      if cursor && cursor["pageDirection"] == "previous",
        do: flip(opts.direction),
        else: opts.direction

    opts
    |> positioned_list_query()
    |> apply_cursor(cursor, opts, query_direction)
    |> apply_list_order(opts.sort, query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> maybe_reverse(cursor)
  end

  defp base_list_query(opts) do
    base =
      from m in MemberProfile,
        join: p in UserProfile,
        on: p.id == m.user_profile_id,
        left_join: u in AuthUser,
        on: u.id == p.supabase_user_id,
        left_join: wg in "waitlist_guardians",
        on: field(wg, :profile_id) == p.id

    base
    |> filter_membership_status(opts.membership_status)
    |> filter_list_search(opts.q)
  end

  defp filter_membership_status(query, nil), do: query
  defp filter_membership_status(query, []), do: query

  defp filter_membership_status(query, statuses) do
    expr =
      Enum.reduce(statuses, nil, fn status, acc ->
        clause = status_clause(status)

        if is_nil(acc) do
          clause
        else
          dynamic([m, p], ^acc or ^clause)
        end
      end)

    where(query, [m, p], ^expr)
  end

  defp status_clause("inactive"), do: dynamic([_m, p], p.is_active == false)

  defp status_clause("paused"),
    do:
      dynamic(
        [m, _p],
        not is_nil(m.subscription_paused_until) and
          m.subscription_paused_until > fragment("NOW()")
      )

  defp status_clause("active"),
    do:
      dynamic(
        [m, p],
        p.is_active == true and
          (is_nil(m.subscription_paused_until) or m.subscription_paused_until <= fragment("NOW()"))
      )

  defp filter_list_search(query, nil), do: query

  defp filter_list_search(query, q) do
    where(
      query,
      [_m, p, _u, _wg],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(p, :search_text), ^q)
    )
  end

  defp positioned_list_query(opts) do
    opts
    |> base_list_query()
    |> select(
      [m, p, u, wg],
      %{
        id: m.id,
        first_name: p.first_name,
        last_name: p.last_name,
        email: u.email,
        phone_number: p.phone_number,
        gender: p.gender,
        pronouns: p.pronouns,
        is_active: p.is_active,
        preferred_weapon: m.preferred_weapon,
        membership_start_date: m.membership_start_date,
        membership_end_date: m.membership_end_date,
        last_payment_date: m.last_payment_date,
        insurance_form_submitted: m.insurance_form_submitted,
        age: fragment(@age_years_sql, p.date_of_birth),
        social_media_consent: type(p.social_media_consent, :string),
        next_of_kin_name: m.next_of_kin_name,
        next_of_kin_phone: m.next_of_kin_phone,
        guardian_first_name: field(wg, :first_name),
        guardian_last_name: field(wg, :last_name),
        guardian_phone_number: field(wg, :phone_number),
        medical_conditions: p.medical_conditions,
        subscription_paused_until: m.subscription_paused_until,
        membership_status:
          fragment(
            "CASE WHEN ? = false THEN 'inactive' WHEN ? IS NOT NULL AND ? > NOW() THEN 'paused' ELSE 'active' END",
            p.is_active,
            m.subscription_paused_until,
            m.subscription_paused_until
          ),
        # Coalesced sort helpers for nullable date sort fields, so cursor
        # comparators have a deterministic non-null value to compare against.
        last_payment_date_sort: fragment("coalesce(?, ?)", m.last_payment_date, ^@epoch_datetime),
        subscription_paused_until_sort:
          fragment("coalesce(?, ?)", m.subscription_paused_until, ^@epoch_datetime)
      }
    )
    |> subquery()
  end

  defp apply_cursor(query, nil, _opts, _query_direction), do: query

  defp apply_cursor(query, cursor, opts, query_direction) do
    op = comparator(opts.direction, query_direction)
    id = cursor["id"]
    value = cursor_value_for_sort(cursor["value"], opts.sort)

    apply_cursor_comparison(query, opts.sort, op, value, id)
  end

  # String sort fields
  defp apply_cursor_comparison(query, "firstName", :after, value, id),
    do: where(query, [e], e.first_name > ^value or (e.first_name == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "firstName", :before, value, id),
    do: where(query, [e], e.first_name < ^value or (e.first_name == ^value and e.id < ^id))

  defp apply_cursor_comparison(query, "lastName", :after, value, id),
    do: where(query, [e], e.last_name > ^value or (e.last_name == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "lastName", :before, value, id),
    do: where(query, [e], e.last_name < ^value or (e.last_name == ^value and e.id < ^id))

  defp apply_cursor_comparison(query, "email", :after, value, id),
    do: where(query, [e], e.email > ^value or (e.email == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "email", :before, value, id),
    do: where(query, [e], e.email < ^value or (e.email == ^value and e.id < ^id))

  defp apply_cursor_comparison(query, "phoneNumber", :after, value, id),
    do: where(query, [e], e.phone_number > ^value or (e.phone_number == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "phoneNumber", :before, value, id),
    do: where(query, [e], e.phone_number < ^value or (e.phone_number == ^value and e.id < ^id))

  # Integer age
  defp apply_cursor_comparison(query, "age", :after, value, id),
    do: where(query, [e], e.age > ^value or (e.age == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "age", :before, value, id),
    do: where(query, [e], e.age < ^value or (e.age == ^value and e.id < ^id))

  # Datetime sort fields
  defp apply_cursor_comparison(query, "membershipStartDate", :after, value, id),
    do:
      where(
        query,
        [e],
        e.membership_start_date > type(^value, :utc_datetime) or
          (e.membership_start_date == type(^value, :utc_datetime) and e.id > ^id)
      )

  defp apply_cursor_comparison(query, "membershipStartDate", :before, value, id),
    do:
      where(
        query,
        [e],
        e.membership_start_date < type(^value, :utc_datetime) or
          (e.membership_start_date == type(^value, :utc_datetime) and e.id < ^id)
      )

  defp apply_cursor_comparison(query, "lastPaymentDate", :after, value, id),
    do:
      where(
        query,
        [e],
        e.last_payment_date_sort > type(^value, :utc_datetime) or
          (e.last_payment_date_sort == type(^value, :utc_datetime) and e.id > ^id)
      )

  defp apply_cursor_comparison(query, "lastPaymentDate", :before, value, id),
    do:
      where(
        query,
        [e],
        e.last_payment_date_sort < type(^value, :utc_datetime) or
          (e.last_payment_date_sort == type(^value, :utc_datetime) and e.id < ^id)
      )

  defp apply_cursor_comparison(query, "subscriptionPausedUntil", :after, value, id),
    do:
      where(
        query,
        [e],
        e.subscription_paused_until_sort > type(^value, :utc_datetime) or
          (e.subscription_paused_until_sort == type(^value, :utc_datetime) and e.id > ^id)
      )

  defp apply_cursor_comparison(query, "subscriptionPausedUntil", :before, value, id),
    do:
      where(
        query,
        [e],
        e.subscription_paused_until_sort < type(^value, :utc_datetime) or
          (e.subscription_paused_until_sort == type(^value, :utc_datetime) and e.id < ^id)
      )

  # Boolean isActive (false < true in Postgres)
  defp apply_cursor_comparison(query, "isActive", :after, value, id),
    do: where(query, [e], e.is_active > ^value or (e.is_active == ^value and e.id > ^id))

  defp apply_cursor_comparison(query, "isActive", :before, value, id),
    do: where(query, [e], e.is_active < ^value or (e.is_active == ^value and e.id < ^id))

  defp apply_list_order(query, sort, direction) do
    order_field = list_order_field(sort)

    case direction do
      "asc" -> order_by(query, [e], asc: field(e, ^order_field), asc: e.id)
      "desc" -> order_by(query, [e], desc: field(e, ^order_field), desc: e.id)
    end
  end

  defp list_order_field("firstName"), do: :first_name
  defp list_order_field("lastName"), do: :last_name
  defp list_order_field("email"), do: :email
  defp list_order_field("phoneNumber"), do: :phone_number
  defp list_order_field("age"), do: :age
  defp list_order_field("membershipStartDate"), do: :membership_start_date
  defp list_order_field("lastPaymentDate"), do: :last_payment_date_sort
  defp list_order_field("subscriptionPausedUntil"), do: :subscription_paused_until_sort
  defp list_order_field("isActive"), do: :is_active

  defp comparator("asc", "asc"), do: :after
  defp comparator("asc", "desc"), do: :before
  defp comparator("desc", "desc"), do: :before
  defp comparator("desc", "asc"), do: :after

  defp flip("asc"), do: "desc"
  defp flip("desc"), do: "asc"

  defp maybe_reverse(rows, %{"pageDirection" => "previous"}), do: Enum.reverse(rows)
  defp maybe_reverse(rows, _cursor), do: rows

  defp next_cursor([], _rows, _opts, _cursor), do: nil

  defp next_cursor(visible_rows, _rows, opts, %{"pageDirection" => "previous"}) do
    visible_rows |> List.last() |> encode_cursor(opts, "next")
  end

  defp next_cursor(visible_rows, rows, opts, _cursor) do
    if length(rows) > opts.limit,
      do: visible_rows |> List.last() |> encode_cursor(opts, "next")
  end

  defp previous_cursor([], _rows, _opts, _cursor), do: nil
  defp previous_cursor(_visible_rows, _rows, _opts, nil), do: nil

  defp previous_cursor(visible_rows, rows, opts, %{"pageDirection" => "previous"}) do
    if length(rows) > opts.limit,
      do: visible_rows |> List.first() |> encode_cursor(opts, "previous")
  end

  defp previous_cursor(visible_rows, _rows, opts, _cursor) do
    visible_rows |> List.first() |> encode_cursor(opts, "previous")
  end

  defp encode_cursor(nil, _opts, _page_direction), do: nil

  defp encode_cursor(row, opts, page_direction) do
    %{
      limit: opts.limit,
      sort: opts.sort,
      direction: opts.direction,
      membershipStatus: opts.membership_status,
      q: opts.q,
      id: row.id,
      value: cursor_value(row, opts.sort),
      pageDirection: page_direction
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # Cursor values are stored as JSON; decode re-parses them back into the
  # Ecto-comparable shape via `cursor_value_for_sort/2`.
  defp cursor_value(row, "firstName"), do: row.first_name
  defp cursor_value(row, "lastName"), do: row.last_name
  defp cursor_value(row, "email"), do: row.email
  defp cursor_value(row, "phoneNumber"), do: row.phone_number
  defp cursor_value(row, "age"), do: row.age

  defp cursor_value(row, "membershipStartDate"),
    do: DateTime.to_iso8601(row.membership_start_date)

  defp cursor_value(row, "lastPaymentDate"), do: DateTime.to_iso8601(row.last_payment_date_sort)

  defp cursor_value(row, "subscriptionPausedUntil"),
    do: DateTime.to_iso8601(row.subscription_paused_until_sort)

  defp cursor_value(row, "isActive"), do: row.is_active

  # Normalises the decoded JSON cursor value into the Ecto-comparable term
  # for the chosen sort field (strings stay strings, ints stay ints, datetime
  # strings are parsed back into `DateTime`, booleans stay booleans).
  defp cursor_value_for_sort(value, sort)
       when sort in ~w(firstName lastName email phoneNumber age isActive),
       do: value

  defp cursor_value_for_sort(value, sort)
       when sort in ~w(membershipStartDate lastPaymentDate subscriptionPausedUntil) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> @epoch_datetime
    end
  end
end
