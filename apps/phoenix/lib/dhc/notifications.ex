defmodule Dhc.Notifications do
  @moduledoc """
  Notifications context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @allowed_limits [10, 25, 50]
  @sort_specs %{
    "createdAt" => %{field: :created_at, type: :utc_datetime, encode: &DateTime.to_iso8601/1}
  }

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
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &cursor_context/1) do
      unread_count = unread_count(user_id)
      rows = notification_rows(user_id, opts, cursor)
      page = CursorPagination.forward_page(rows, opts, &cursor_context/1, &cursor_value/2)

      {:ok,
       %{
         notifications: page.visible_rows,
         unread_count: unread_count,
         next_cursor: page.next_cursor
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

  defp cursor_context(opts),
    do: %{"limit" => opts.limit, "sort" => "createdAt", "direction" => "desc"}

  defp unread_count(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
    |> select([n], count(n.id))
    |> Repo.one()
  end

  defp notification_rows(user_id, opts, cursor) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> CursorPagination.apply_cursor(
      cursor,
      Map.merge(opts, %{sort: "createdAt", direction: "desc"}),
      @sort_specs
    )
    |> CursorPagination.apply_order(:created_at, "desc")
    |> limit(^opts.limit + 1)
    |> Repo.all()
  end

  defp cursor_value(row, _opts), do: DateTime.to_iso8601(row.created_at)
end
