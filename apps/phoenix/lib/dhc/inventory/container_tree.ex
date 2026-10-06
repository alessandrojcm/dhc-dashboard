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
    * **Cycle check** — `in_subtree?/2` tells a move whether its proposed
      parent sits under the moving container.
    * **Path names** — `path_names/1` renders `"Root › … › Leaf"` for many
      containers from the same recursive ancestor query as `ancestors/1`.

  This module decides **how** a chain is walked or locked, never **when**:
  `Dhc.Inventory.AvailabilityCommands.with_locked_item/2` (ADR 0023) still
  share-locks the chain root first and before the item `FOR UPDATE`, and
  container archive still takes the target `FOR UPDATE` before its subtree.
  All functions run on the caller's connection, so the locking ones only
  hold their locks inside the caller's transaction.
  """

  import Ecto.Query

  alias Dhc.Inventory.Container
  alias Dhc.Repo

  @path_separator " › "

  @typedoc "One container on an ancestor chain."
  @type link :: %{id: Ecto.UUID.t(), archived_at: DateTime.t() | nil}

  # The one recursive ancestor walk. Every requested id starts a chain
  # (`origin_id`); each step climbs to the parent, so `depth` 0 is the
  # container itself and the highest depth is its root. `ancestors/1`
  # and `path_names/1` both read these rows.
  @ancestor_rows_sql """
  WITH RECURSIVE ancestors AS (
    SELECT id AS origin_id, id, parent_container_id, name, archived_at, 0 AS depth
    FROM containers
    WHERE id = ANY($1)
    UNION ALL
    SELECT child.origin_id, parent.id, parent.parent_container_id, parent.name,
           parent.archived_at, child.depth + 1
    FROM containers parent
    JOIN ancestors child ON child.parent_container_id = parent.id
  )
  SELECT origin_id, id, name, archived_at
  FROM ancestors
  ORDER BY origin_id, depth DESC
  """

  # Chains keyed by origin id, each root first. Ids that are not UUIDs or do
  # not exist have no chain.
  defp ancestor_chains(container_ids) do
    case dump_ids(container_ids) do
      [] ->
        %{}

      ids ->
        %{rows: rows} = Repo.query!(@ancestor_rows_sql, [ids])

        Enum.group_by(
          rows,
          fn [origin_id | _rest] -> Ecto.UUID.load!(origin_id) end,
          fn [_origin_id, id, name, archived_at] ->
            %{id: Ecto.UUID.load!(id), name: name, archived_at: archived_at}
          end
        )
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

  @doc """
  The chain from the root down to `container_id`, inclusive, unlocked.

  Returns `[]` when the container does not exist.
  """
  @spec ancestors(Ecto.UUID.t()) :: [link()]
  def ancestors(container_id) when is_binary(container_id) do
    [container_id]
    |> ancestor_chains()
    |> Map.get(container_id, [])
    |> Enum.map(&Map.take(&1, [:id, :archived_at]))
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
    from(c in Container,
      where: c.id == ^id,
      select: %{id: c.id, archived_at: c.archived_at},
      lock: "FOR SHARE"
    )
    |> Repo.all()
  end

  @doc """
  Whether nothing from `container_id` up to the root is archived and the
  container exists. Unlocked.

  `nil` is the top of the tree (a root's parent, or no container at all), so
  there is nothing above it that could be archived.
  """
  @spec chain_active?(Ecto.UUID.t() | nil) :: boolean()
  def chain_active?(nil), do: true

  def chain_active?(container_id) when is_binary(container_id) do
    case ancestors(container_id) do
      [] -> false
      chain -> Enum.all?(chain, &is_nil(&1.archived_at))
    end
  end

  @doc """
  Whether `container_id` is `root_id` itself or anywhere below it.

  Moving a container under a parent in its own subtree would be a cycle:
  `in_subtree?(proposed_parent_id, container_id)` answers that before the
  acyclic constraint has to.
  """
  @spec in_subtree?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def in_subtree?(container_id, root_id) when container_id == root_id, do: true

  def in_subtree?(container_id, root_id) when is_binary(container_id) and is_binary(root_id) do
    container_id |> ancestors() |> Enum.any?(&(&1.id == root_id))
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
  def all_ids, do: from(c in Container, select: c.id) |> Repo.all()

  @doc """
  The full path from the root for each id, as `"Root › … › Leaf"`.

  Reads the same recursive ancestor walk as `ancestors/1`, for every
  requested id at once. Ids that do not exist (or are not UUIDs) are absent
  from the map; a root maps to its own name.
  """
  @spec path_names([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def path_names(container_ids) when is_list(container_ids) do
    container_ids
    |> ancestor_chains()
    |> Map.new(fn {id, chain} -> {id, Enum.map_join(chain, @path_separator, & &1.name)} end)
  end
end
