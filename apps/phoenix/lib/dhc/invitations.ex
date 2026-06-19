defmodule Dhc.Invitations do
  @moduledoc """
  Invitation context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @invite_email_template "inviteMember"

  # ── List (cursor pagination) ─────────────────────────────────────────
  # The dashboard invitations table reads only `pending` and `expired` rows,
  # mirroring the previous hardcoded client filter. There is no `status`
  # query param — `accepted`/`revoked` rows are never returned — but the
  # `status` field is still present in the DTO for badge rendering.
  @allowed_limits [10, 25, 50, 100]
  @allowed_sort_fields ~w(email status expiresAt createdAt)
  @allowed_directions ~w(asc desc)
  @visible_statuses ~w(pending expired)

  @doc """
  Returns cursor-paginated, domain-shaped member invitations for the dashboard.

  The server always filters to `pending` and `expired` invitations. Cursor
  payloads bind to the query semantics (limit, search, sort and direction),
  so stale cursors from a different table state return an explicit
  `{:error, :bad_cursor}` instead of silently serving the wrong page.

  `totalCount` is an exact `COUNT(*)`, not an estimated count, replacing the
  prior client-side estimated count.
  """
  @spec list(map()) :: {:ok, map()} | {:error, atom()}
  def list(params \\ %{}) do
    with {:ok, opts} <- parse_list_options(params),
         {:ok, cursor} <- parse_cursor(opts) do
      total_count = list_total_count(opts)
      rows = list_rows(opts, cursor)
      visible_rows = Enum.take(rows, opts.limit)

      {:ok,
       %{
         invitations: visible_rows,
         total_count: total_count,
         limit: opts.limit,
         next_cursor: next_cursor(visible_rows, rows, opts, cursor),
         previous_cursor: previous_cursor(visible_rows, rows, opts, cursor)
       }}
    end
  end

  @doc """
  Re-enqueues invite-member emails for existing invitations.
  """
  @spec resend_invitation_emails([String.t()]) ::
          {:ok, %{succeeded: non_neg_integer(), failed: non_neg_integer()}}
  def resend_invitation_emails(emails) when is_list(emails) and length(emails) > 0 do
    invite_data = list_invitation_resend_data(emails)

    succeeded =
      invite_data
      |> Enum.map(&enqueue_invitation_email/1)
      |> Enum.count(&match?(:ok, &1))

    found_emails = Enum.map(invite_data, & &1.email)

    if found_emails != [] do
      expire_for_resend(found_emails)
    end

    {:ok, %{succeeded: succeeded, failed: length(emails) - succeeded}}
  end

  def resend_invitation_emails(_emails), do: {:ok, %{succeeded: 0, failed: 0}}

  defp list_invitation_resend_data(emails) do
    from(i in Invitation,
      left_join: up in UserProfile,
      on: up.supabase_user_id == i.user_id,
      where: i.email in ^emails,
      select: %{
        id: i.id,
        email: i.email,
        first_name: up.first_name,
        last_name: up.last_name,
        date_of_birth: up.date_of_birth
      }
    )
    |> Repo.all()
  end

  defp enqueue_invitation_email(invitation) do
    args = %{
      "email" => invitation.email,
      "transactional_id" => @invite_email_template,
      "data_variables" => %{
        "firstName" => invitation.first_name || "",
        "lastName" => invitation.last_name || "",
        "invitationLink" => invitation_link(invitation)
      }
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_for_resend(emails) do
    from(i in Invitation, where: i.email in ^emails)
    |> Repo.update_all(
      set: [status: "pending", expires_at: DateTime.add(DateTime.utc_now(), 1, :day)]
    )
  end

  defp invitation_link(invitation) do
    app_url = Application.fetch_env!(:dhc, :app_url)

    app_url
    |> URI.merge("/members/signup/#{invitation.id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => Repository.date_string(invitation.date_of_birth),
        "email" => invitation.email
      })
    )
    |> URI.to_string()
  end

  # ── List helpers ─────────────────────────────────────────────────────

  defp parse_list_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    sort = Map.get(params, "sort", "createdAt")
    direction = Map.get(params, "direction", "desc")
    q = blank_to_nil(Map.get(params, "q"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      sort not in @allowed_sort_fields ->
        {:error, :invalid_sort}

      direction not in @allowed_directions ->
        {:error, :invalid_direction}

      true ->
        {:ok,
         %{
           limit: limit,
           sort: sort,
           direction: direction,
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
      cursor["direction"] == opts.direction and cursor["q"] == opts.q
  end

  defp list_total_count(opts) do
    opts
    |> base_list_query()
    |> select([i], count(i.id))
    |> Repo.one()
  end

  defp list_rows(opts, cursor) do
    query_direction =
      if cursor && cursor["pageDirection"] == "previous",
        do: flip(opts.direction),
        else: opts.direction

    opts
    |> base_list_query()
    |> apply_cursor(cursor, opts, query_direction)
    |> apply_list_order(opts.sort, query_direction)
    |> limit(^opts.limit + 1)
    |> Repo.all()
    |> maybe_reverse(cursor)
  end

  defp base_list_query(opts) do
    base_query =
      from i in Invitation,
        where: i.status in ^@visible_statuses

    base_query
    |> filter_list_search(opts.q)
  end

  # `search_text` is a generated tsvector column on `invitations`; websearch
  # over it replaces the prior client-side `textSearch("search_text", ...)`.
  defp filter_list_search(query, nil), do: query

  defp filter_list_search(query, q) do
    where(
      query,
      [i],
      fragment("? @@ websearch_to_tsquery('english', ?)", field(i, :search_text), ^q)
    )
  end

  defp apply_cursor(query, nil, _opts, _query_direction), do: query

  defp apply_cursor(query, cursor, opts, query_direction) do
    op = comparator(opts.direction, query_direction)
    id = cursor["id"]
    value = cursor["value"]

    apply_cursor_comparison(query, opts.sort, op, value, id)
  end

  # The cursor stores the sort field's value at the anchor row. We page
  # strictly past (next) or before (previous) that row, breaking ties with
  # the immutable `id` so pagination is stable across concurrent writes.
  defp apply_cursor_comparison(query, "email", :after, value, id),
    do:
      where(
        query,
        [i],
        i.email > ^value or (i.email == ^value and i.id > ^id)
      )

  defp apply_cursor_comparison(query, "email", :before, value, id),
    do:
      where(
        query,
        [i],
        i.email < ^value or (i.email == ^value and i.id < ^id)
      )

  defp apply_cursor_comparison(query, "status", :after, value, id),
    do: where(query, [i], i.status > ^value or (i.status == ^value and i.id > ^id))

  defp apply_cursor_comparison(query, "status", :before, value, id),
    do: where(query, [i], i.status < ^value or (i.status == ^value and i.id < ^id))

  defp apply_cursor_comparison(query, "expiresAt", :after, value, id),
    do:
      where(
        query,
        [i],
        i.expires_at > type(^value, :utc_datetime) or
          (i.expires_at == type(^value, :utc_datetime) and i.id > ^id)
      )

  defp apply_cursor_comparison(query, "expiresAt", :before, value, id),
    do:
      where(
        query,
        [i],
        i.expires_at < type(^value, :utc_datetime) or
          (i.expires_at == type(^value, :utc_datetime) and i.id < ^id)
      )

  defp apply_cursor_comparison(query, "createdAt", :after, value, id),
    do:
      where(
        query,
        [i],
        i.created_at > type(^value, :utc_datetime) or
          (i.created_at == type(^value, :utc_datetime) and i.id > ^id)
      )

  defp apply_cursor_comparison(query, "createdAt", :before, value, id),
    do:
      where(
        query,
        [i],
        i.created_at < type(^value, :utc_datetime) or
          (i.created_at == type(^value, :utc_datetime) and i.id < ^id)
      )

  defp apply_list_order(query, sort, direction) do
    order_field = list_order_field(sort)

    case direction do
      "asc" -> order_by(query, [i], asc: field(i, ^order_field), asc: i.id)
      "desc" -> order_by(query, [i], desc: field(i, ^order_field), desc: i.id)
    end
  end

  defp list_order_field("email"), do: :email
  defp list_order_field("status"), do: :status
  defp list_order_field("expiresAt"), do: :expires_at
  defp list_order_field("createdAt"), do: :created_at

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
    if length(rows) > opts.limit, do: visible_rows |> List.last() |> encode_cursor(opts, "next")
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
      q: opts.q,
      id: row.id,
      value: cursor_value(row, opts.sort),
      pageDirection: page_direction
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp cursor_value(row, "email"), do: row.email
  defp cursor_value(row, "status"), do: row.status

  defp cursor_value(row, "expiresAt"),
    do: DateTime.to_iso8601(row.expires_at)

  defp cursor_value(row, "createdAt"),
    do: DateTime.to_iso8601(row.created_at)
end
