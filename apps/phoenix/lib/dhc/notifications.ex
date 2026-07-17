defmodule Dhc.Notifications do
  @moduledoc """
  Notifications context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Notifications.Broadcaster
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @allowed_limits [10, 25, 50]
  @sort_specs %{
    "createdAt" => %{field: :created_at, type: :utc_datetime, encode: &DateTime.to_iso8601/1}
  }

  @doc """
  Creates a Notification for a user.

  This is the **only** supported application API for Notification creation.
  Raw insertion is private to this context; callers that need a Notification
  must go through `create/2` so post-commit signalling cannot be bypassed.

  Behaviour:

    * Rejects calls made while the calling process is already inside a
      repository transaction (`Repo.in_transaction?/0`). A nested call could
      let the post-commit broadcast fire before the outer transaction
      commits (or rolls it back), exposing data that may never become
      durable. Fail fast with `{:error, :notification_create_inside_transaction}`.
      A future workflow needing atomic creation with other writes must own
      its own outermost transaction and broadcast after it returns.
    * Inserts the row via an `Ecto.Multi` transaction owned by this context
      using `Repo.transact/2`, which commits before returning `{:ok, _}`.
    * After a successful commit, makes exactly one best-effort broadcast
      attempt to the owner's per-user topic. A broadcast failure is logged
      with the Notification and user identifiers but does NOT turn the
      committed write into an application error — callers see `:ok` and the
      row remains.
    * A failed insert or rolled-back transaction creates no row and emits no
      signal.

  Returns `:ok` on a successful commit (regardless of broadcast outcome) and
  `{:error, reason}` on a rejected nested call or insert failure.
  """
  @spec create(String.t(), String.t()) :: :ok | {:error, term()}
  def create(user_id, body) when is_binary(user_id) and is_binary(body) do
    if Repo.in_transaction?() do
      {:error, :notification_create_inside_transaction}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:notification, notification_changeset(user_id, body))
      |> Repo.transact()
      |> after_commit_signal()
    end
  end

  defp after_commit_signal({:ok, %{notification: notification}}) do
    # Best-effort: the row is already durably committed by Repo.transact/2.
    # A broadcast failure is logged inside the broadcaster but does not
    # change the successful database result returned to callers.
    _ = Broadcaster.notification_created(notification)
    :ok
  end

  defp after_commit_signal({:error, _operation, reason, _changes}), do: {:error, reason}

  defp notification_changeset(user_id, body) do
    changeset =
      %Notification{}
      |> Ecto.Changeset.cast(%{body: body}, [:body])
      |> Ecto.Changeset.validate_required([:body])

    case Ecto.UUID.cast(user_id) do
      {:ok, user_id} -> Ecto.Changeset.put_change(changeset, :user_id, user_id)
      :error -> Ecto.Changeset.add_error(changeset, :user_id, "is invalid")
    end
  end

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

  @doc "Marks one notification as read when it belongs to the authenticated user."
  @spec mark_read(String.t(), String.t()) :: {:ok, Notification.t()} | {:error, :not_found}
  def mark_read(user_id, notification_id)
      when is_binary(user_id) and is_binary(notification_id) do
    case Repo.get_by(Notification, id: notification_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      notification ->
        notification
        |> Ecto.Changeset.change(
          read_at: notification.read_at || DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()
    end
  end

  @doc "Marks every unread notification belonging to the authenticated user as read."
  @spec mark_all_read(String.t()) :: {:ok, non_neg_integer()}
  def mark_all_read(user_id) when is_binary(user_id) do
    {updated_count, _} =
      Notification
      |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    {:ok, updated_count}
  end

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
