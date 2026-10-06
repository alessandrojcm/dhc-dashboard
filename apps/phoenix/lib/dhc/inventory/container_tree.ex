defmodule Dhc.Inventory.ContainerTree do
  @moduledoc """
  ALE-346: the one module that walks the Container hierarchy.

  Every recursive read of `containers.parent_container_id` lives here, so the
  ancestor order, the subtree definition, and the path rendering cannot drift
  between the guards, the container lifecycle, the loan approval snapshot, and
  operator search.

    * **Ancestors** — `ancestors/1` (read-only) and `lock_ancestors_for_share/1`,
      both root first.
    * **Subtree** — `active_dependants?/1` and `lock_subtree_for_update/1`
      walk a container and every descendant.
    * **Path names** — `path_names/1` renders `"Root › … › Leaf"` for many
      containers in one recursive query.

  This module decides **how** a chain is walked or locked, never **when**:
  `Dhc.Inventory.AvailabilityCommands.with_locked_item/2` (ADR 0023) still
  share-locks the chain root first and before the item `FOR UPDATE`, and
  container archive still takes the target `FOR UPDATE` before its subtree.
  All functions run on the caller's connection, so the locking ones only
  hold their locks inside the caller's transaction.
  """

  import Ecto.Query

  alias Dhc.Repo

  @path_separator " › "

  @typedoc "One container on an ancestor chain."
  @type link :: %{id: Ecto.UUID.t(), archived_at: DateTime.t() | nil}

  @doc """
  The chain from the root down to `container_id`, inclusive, unlocked.

  Returns `[]` when the container does not exist.
  """
  @spec ancestors(Ecto.UUID.t()) :: [link()]
  def ancestors(container_id) when is_binary(container_id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE chain AS (
          SELECT id, parent_container_id, archived_at, 0 AS depth
          FROM containers
          WHERE id = $1
          UNION ALL
          SELECT parent.id, parent.parent_container_id, parent.archived_at, child.depth + 1
          FROM containers parent
          JOIN chain child ON child.parent_container_id = parent.id
        )
        SELECT id, archived_at FROM chain ORDER BY depth DESC
        """,
        [Ecto.UUID.dump!(container_id)]
      )

    Enum.map(rows, fn [id, archived_at] ->
      %{id: Ecto.UUID.load!(id), archived_at: archived_at}
    end)
  end

  @doc """
  The ancestor chain of `container_id`, each row share-locked root first.

  Reads the chain, then takes one `FOR SHARE` per row from the root down.
  Root-first matches container archive (target, then dependants walking
  down), so a move or restore cannot deadlock against an archive of an
  ancestor; the real rows are locked, so a concurrent archive waits rather
  than committing under the check. The returned rows are the locked
  re-reads, so `archived_at` is authoritative for the rest of the
  transaction. A missing container, or a link deleted between the walk and
  its lock, is `{:error, :not_found}`.
  """
  @spec lock_ancestors_for_share(Ecto.UUID.t()) :: {:ok, [link(), ...]} | {:error, :not_found}
  def lock_ancestors_for_share(container_id) when is_binary(container_id) do
    case ancestors(container_id) do
      [] ->
        {:error, :not_found}

      chain ->
        locked = Enum.flat_map(chain, &share_lock(&1.id))
        if length(locked) == length(chain), do: {:ok, locked}, else: {:error, :not_found}
    end
  end

  defp share_lock(id) do
    from(c in "containers",
      where: c.id == type(^id, :binary_id),
      select: %{id: type(c.id, :binary_id), archived_at: c.archived_at},
      lock: "FOR SHARE"
    )
    |> Repo.all()
  end

  @doc """
  Whether `container_id` exists and nothing from it up to the root is
  archived. Unlocked.
  """
  @spec chain_active?(Ecto.UUID.t()) :: boolean()
  def chain_active?(container_id) when is_binary(container_id) do
    container_id |> ancestors() |> active_chain?()
  end

  defp active_chain?([]), do: false
  defp active_chain?(chain), do: Enum.all?(chain, &is_nil(&1.archived_at))

  @doc """
  Whether `ancestor_id` is `container_id` itself or one of its ancestors.

  Moving a container under its own descendant would be a cycle; this is the
  check that answers it before the acyclic constraint has to.
  """
  @spec self_or_ancestor?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def self_or_ancestor?(ancestor_id, container_id) when ancestor_id == container_id, do: true

  def self_or_ancestor?(ancestor_id, container_id)
      when is_binary(ancestor_id) and is_binary(container_id) do
    container_id |> ancestors() |> Enum.any?(&(&1.id == ancestor_id))
  end

  @doc """
  Whether anything below `container_id` is still active: a descendant
  container (excluding the container itself) or an item anywhere in the
  subtree.
  """
  @spec active_dependants?(Ecto.UUID.t()) :: boolean()
  def active_dependants?(container_id) when is_binary(container_id) do
    %{rows: [[active_dependants?]]} =
      query_subtree!(
        """
        SELECT
          EXISTS (
            SELECT 1
            FROM containers container
            JOIN subtree ON subtree.id = container.id
            WHERE container.id <> $1 AND container.archived_at IS NULL
          )
          OR EXISTS (
            SELECT 1
            FROM inventory_items item
            JOIN subtree ON subtree.id = item.container_id
            WHERE item.archived_at IS NULL
          )
        """,
        container_id
      )

    active_dependants?
  end

  @doc """
  Lock every container in the subtree of `container_id`, then every item in
  it, `FOR UPDATE`, each in id order.

  Containers before items keeps the container-before-item order every
  inventory command shares.
  """
  @spec lock_subtree_for_update(Ecto.UUID.t()) :: :ok
  def lock_subtree_for_update(container_id) when is_binary(container_id) do
    query_subtree!(
      """
      SELECT container.id
      FROM containers container
      JOIN subtree ON subtree.id = container.id
      ORDER BY container.id
      FOR UPDATE
      """,
      container_id
    )

    query_subtree!(
      """
      SELECT item.id
      FROM inventory_items item
      JOIN subtree ON subtree.id = item.container_id
      ORDER BY item.id
      FOR UPDATE
      """,
      container_id
    )

    :ok
  end

  # Shared recursive walk of a container and every descendant; the callers
  # differ only in the SELECT that follows.
  defp query_subtree!(select_sql, container_id) do
    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM containers WHERE id = $1
        UNION ALL
        SELECT child.id
        FROM containers child
        JOIN subtree parent ON parent.id = child.parent_container_id
      )
      """ <> select_sql,
      [Ecto.UUID.dump!(container_id)]
    )
  end

  @doc """
  Every container id, for callers that render paths for the whole tree.
  """
  @spec all_ids() :: [Ecto.UUID.t()]
  def all_ids do
    from(c in "containers", select: type(c.id, :binary_id)) |> Repo.all()
  end

  @doc """
  The full path from the root for each id, as `"Root › … › Leaf"`.

  One recursive query walks every requested chain at once. Ids that do not
  exist (or are not UUIDs) are absent from the map; a root maps to its own
  name.
  """
  @spec path_names([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def path_names(container_ids) when is_list(container_ids) do
    case dump_ids(container_ids) do
      [] ->
        %{}

      ids ->
        %{rows: rows} =
          Repo.query!(
            """
            WITH RECURSIVE ancestors AS (
              SELECT id AS origin_id, id, parent_container_id, name, 0 AS depth
              FROM containers
              WHERE id = ANY($1)
              UNION ALL
              SELECT child.origin_id, parent.id, parent.parent_container_id, parent.name,
                     child.depth + 1
              FROM containers parent
              JOIN ancestors child ON child.parent_container_id = parent.id
            )
            SELECT origin_id, string_agg(name, $2 ORDER BY depth DESC)
            FROM ancestors
            GROUP BY origin_id
            """,
            [ids, @path_separator]
          )

        Map.new(rows, fn [id, path] -> {Ecto.UUID.load!(id), path} end)
    end
  end

  defp dump_ids(container_ids) do
    container_ids
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.dump(id) do
        {:ok, dumped} -> [dumped]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end
end
