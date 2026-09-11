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
  def create(principal_id, body) when is_binary(principal_id) and is_binary(body) do
    if Repo.in_transaction?() do
      {:error, :notification_create_inside_transaction}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:notification, notification_changeset(principal_id, body))
      |> Repo.transact()
      |> after_commit_signal()
    end
  end

  @doc """
  Creates a Notification **at most once** for a `(principal_id, key)` pair.

  `create/2` is at-least-once by construction: a caller that crashes or retries
  after the commit creates a second row. Every notification ALE-280 asks for is
  emitted from a retryable context — an Oban reminder tick, a reconciliation
  pass repairing a missed event, a loan transition a client may resubmit — so
  the caller needs to be able to name the *logical event* and have a repeat be a
  no-op (story 51: no duplicate unread notification per reminder kind across
  retries and scheduler restarts).

  The `key` identifies the event, never the recipient: one overdue loan
  notifies the borrower and every operator, and each gets their own row from the
  same key. Uniqueness is scoped to `(principal_id, key)` in the database, so a
  caller never has to smuggle a principal id into the key string.

  Behaviour beyond `create/2`:

    * Insert is `ON CONFLICT DO NOTHING` against
      `notifications_principal_notification_key_unique`, so a concurrent
      duplicate is a normal outcome and never a `Postgrex.Error`.
    * Returns `{:ok, :created}` when this call created the row and
      `{:ok, :already_created}` when a row for the key already existed. Callers
      that must not act twice (an email, an external side effect) branch on
      this; callers that only need the notification to exist can ignore it.
    * Broadcasts **only** on `:created`. Re-signalling on a retry would make a
      duplicate-suppressed write look like new activity to the recipient's
      client, which is the user-visible half of the duplicate problem.
    * Never updates the existing row. The row is a fact the recipient may
      already have read and acted on; replacing its body or clearing `read_at`
      would resurrect a handled notification.

  Returns `{:error, :invalid_notification_key}` for a blank key rather than
  silently degrading to an unkeyed row, `{:error, :notification_create_inside_transaction}`
  for a nested call, and `{:error, changeset}` for an invalid recipient.
  """
  @spec create_keyed(String.t(), String.t(), String.t()) ::
          {:ok, :created | :already_created} | {:error, term()}
  def create_keyed(principal_id, key, body)
      when is_binary(principal_id) and is_binary(key) and is_binary(body) do
    cond do
      String.trim(key) == "" ->
        {:error, :invalid_notification_key}

      Repo.in_transaction?() ->
        {:error, :notification_create_inside_transaction}

      true ->
        principal_id
        |> notification_changeset(body)
        |> Ecto.Changeset.put_change(:notification_key, String.trim(key))
        |> insert_keyed()
    end
  end

  # The changeset is built (and validated) exactly as for `create/2`, but the
  # write goes through `insert_all` because it is the one insert API that
  # reports whether a row was actually written. `Repo.insert` with
  # `on_conflict: :nothing` cannot answer that here: the schema autogenerates
  # its `binary_id` in Elixir, so the returned struct carries an id whether or
  # not the row reached the table.
  defp insert_keyed(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, %{changeset | action: :insert}}

  defp insert_keyed(%Ecto.Changeset{} = changeset) do
    entry =
      Map.take(Ecto.Changeset.apply_changes(changeset), [:principal_id, :body, :notification_key])

    # `id` and `created_at` are left to their database defaults, so the row's
    # identity and creation time are assigned where the uniqueness decision is
    # made rather than by a caller that may be retrying an old attempt.
    Notification
    |> Repo.insert_all([entry],
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(principal_id, notification_key) WHERE notification_key IS NOT NULL"},
      returning: true
    )
    |> case do
      {0, _none} ->
        {:ok, :already_created}

      {1, [%Notification{} = notification]} ->
        # Best-effort, exactly as in `create/2`: the row is already durable, and
        # only a genuinely new row rings the recipient's bell.
        _ = Broadcaster.notification_created(notification)
        {:ok, :created}
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

  defp notification_changeset(principal_id, body) do
    changeset =
      %Notification{}
      |> Ecto.Changeset.cast(%{body: body}, [:body])
      |> Ecto.Changeset.validate_required([:body])

    case Ecto.UUID.cast(principal_id) do
      {:ok, principal_id} ->
        Ecto.Changeset.put_change(changeset, :principal_id, principal_id)

      :error ->
        Ecto.Changeset.add_error(changeset, :principal_id, "is invalid")
    end
  end

  @doc """
  Returns cursor-paginated, domain-shaped notifications for a single user.

  Callers must pass the authenticated Principal id, and only rows owned by
  that Principal are considered.
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
    case Repo.get_by(Notification, id: notification_id, principal_id: user_id) do
      nil ->
        {:error, :not_found}

      # Already read: keep the original timestamp so re-reading is idempotent
      # and does not rewrite when the recipient actually saw it.
      %Notification{read_at: %DateTime{}} = notification ->
        {:ok, notification}

      %Notification{} = notification ->
        {1, [%Notification{} = updated]} =
          Notification
          |> where([n], n.id == ^notification.id)
          |> select([n], n)
          |> Repo.update_all(set: [read_stamp()])

        {:ok, updated}
    end
  end

  @doc "Marks every unread notification belonging to the authenticated user as read."
  @spec mark_all_read(String.t()) :: {:ok, non_neg_integer()}
  def mark_all_read(user_id) when is_binary(user_id) do
    {updated_count, _} =
      Notification
      |> where([n], n.principal_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_stamp()])

    {:ok, updated_count}
  end

  # `read_at` is stamped by the database and clamped to `created_at`, never
  # computed in Elixir.
  #
  # `notifications` has a `read_at >= created_at` check constraint, and
  # `created_at` defaults to `NOW()` with microsecond precision. Truncating an
  # Elixir `utc_now/0` to the second rounds *down*, so a notification read in
  # the same second it was created produced a `read_at` before its
  # `created_at` and raised `Ecto.ConstraintError` — a 500 on "mark as read"
  # for the newest notification, which is precisely the one a recipient taps.
  # `GREATEST` makes the stamp monotonic with respect to the row it belongs to,
  # and reading the clock in Postgres keeps it consistent with the default that
  # set `created_at`.
  defp read_stamp, do: {:read_at, dynamic([n], fragment("GREATEST(now(), ?)", n.created_at))}

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
    |> where([n], n.principal_id == ^user_id and is_nil(n.read_at))
    |> select([n], count(n.id))
    |> Repo.one()
  end

  defp notification_rows(user_id, opts, cursor) do
    Notification
    |> where([n], n.principal_id == ^user_id)
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
