defmodule Dhc.Notifications do
  @moduledoc """
  Notifications context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @allowed_limits [10, 25, 50]

  @doc """
  Returns cursor-paginated, domain-shaped notifications for a single user.

  The query intentionally mirrors the old `notifications.user_id = auth.uid()`
  RLS boundary in application code: callers must pass the authenticated
  Supabase user id, and only rows for that user are considered.
  """
  @spec list_for_user(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def list_for_user(user_id, params \\ %{})

  def list_for_user(user_id, params) when is_binary(user_id) do
    with {:ok, opts} <- parse_options(params),
         {:ok, cursor} <- parse_cursor(opts) do
      unread_count = unread_count(user_id)
      rows = notification_rows(user_id, opts, cursor)
      visible_rows = Enum.take(rows, opts.limit)

      {:ok,
       %{
         notifications: visible_rows,
         unread_count: unread_count,
         next_cursor: next_cursor(visible_rows, rows, opts)
       }}
    end
  end

  def list_for_user(_user_id, _params), do: {:error, :invalid_user}

  defp parse_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))

    if limit in @allowed_limits do
      {:ok, %{limit: limit, cursor: blank_to_nil(Map.get(params, "cursor"))}}
    else
      {:error, :invalid_limit}
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
         true <- cursor["limit"] == opts.limit,
         {:ok, _id} <- Ecto.UUID.cast(cursor["id"]),
         {:ok, _created_at, _offset} <- DateTime.from_iso8601(cursor["createdAt"]) do
      {:ok, cursor}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp unread_count(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
    |> select([n], count(n.id))
    |> Repo.one()
  end

  defp notification_rows(user_id, opts, cursor) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> apply_cursor(cursor)
    |> order_by([n], desc: n.created_at, desc: n.id)
    |> limit(^opts.limit + 1)
    |> Repo.all()
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor) do
    where(
      query,
      [n],
      n.created_at < type(^cursor["createdAt"], :utc_datetime) or
        (n.created_at == type(^cursor["createdAt"], :utc_datetime) and n.id < ^cursor["id"])
    )
  end

  defp next_cursor([], _rows, _opts), do: nil

  defp next_cursor(visible_rows, rows, opts) do
    if length(rows) > opts.limit, do: visible_rows |> List.last() |> encode_cursor(opts)
  end

  defp encode_cursor(nil, _opts), do: nil

  defp encode_cursor(row, opts) do
    %{
      limit: opts.limit,
      id: row.id,
      createdAt: DateTime.to_iso8601(row.created_at)
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
