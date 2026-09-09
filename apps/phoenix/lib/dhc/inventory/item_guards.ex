defmodule Dhc.Inventory.ItemGuards do
  @moduledoc """
  ALE-284a/b: the shared preconditions of every target item command.

  Item identity resolution and the "is this dependency still active?" checks
  are needed by both the item seam (`Dhc.Inventory.OperatorItems`) and the
  lifecycle seam (`Dhc.Inventory.OperatorItemLifecycle`). They live here so
  the two slices cannot drift on what a slug resolves to, what counts as
  active, or which lock strength a guard takes.

  Every function is meant to be called **inside** the caller's transaction:

    * Items lock `FOR UPDATE`, because the caller is about to change the row
      and all per-item interlocks must queue behind each other.
    * Containers and categories lock `FOR SHARE`, because the caller only
      needs them to stay active for the rest of the transaction — archiving
      one concurrently must wait, not silently win.
  """

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Repo

  @doc """
  Query one item by slug or id. A UUID resolves by id, anything else by slug.
  """
  @spec item_query(String.t()) :: Ecto.Query.t()
  def item_query(slug_or_id) when is_binary(slug_or_id) do
    case Ecto.UUID.cast(slug_or_id) do
      {:ok, id} -> from(i in Item, where: i.id == ^id)
      :error -> from(i in Item, where: i.slug == ^slug_or_id)
    end
  end

  @doc """
  Lock one item `FOR UPDATE`, archived or not.
  """
  @spec lock_item(String.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def lock_item(slug_or_id) when is_binary(slug_or_id) do
    case slug_or_id |> item_query() |> lock("FOR UPDATE") |> Repo.one() do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, item}
    end
  end

  @doc """
  Lock one item `FOR UPDATE` and refuse it when archived.

  An archived item is read-only: restoring it is the way back into any
  command that changes it.
  """
  @spec lock_active_item(String.t()) ::
          {:ok, Item.t()} | {:error, :not_found} | {:error, :archived}
  def lock_active_item(slug_or_id) when is_binary(slug_or_id) do
    case lock_item(slug_or_id) do
      {:ok, %Item{archived_at: archived_at}} when not is_nil(archived_at) -> {:error, :archived}
      other -> other
    end
  end

  @doc """
  Resolve a container id and require it to be active.
  """
  @spec require_active_container(String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found} | {:error, :archived_container}
  def require_active_container(nil), do: {:error, :not_found}

  def require_active_container(container_id) do
    case Ecto.UUID.cast(container_id) do
      :error -> {:error, :not_found}
      {:ok, id} -> check_container(id)
    end
  end

  defp check_container(id) do
    query =
      from(c in "containers",
        where: c.id == type(^id, :binary_id),
        select: %{archived_at: c.archived_at},
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %{archived_at: nil} -> {:ok, id}
      %{archived_at: _archived} -> {:error, :archived_container}
    end
  end

  @doc """
  Require every container from `container_id` up to the root to be active.

  Restoring an item into an archived ancestor would put an active item inside
  retired storage, so the whole chain is checked, not just the direct parent.
  A missing container is reported as archived: either way the chain cannot
  host an active item.
  """
  @spec require_active_container_chain(String.t() | nil) :: :ok | {:error, :archived_container}
  def require_active_container_chain(nil), do: {:error, :archived_container}

  def require_active_container_chain(container_id) do
    result =
      Repo.query!(
        """
        WITH RECURSIVE chain AS (
          SELECT id, parent_container_id, archived_at
          FROM containers
          WHERE id = $1
          UNION ALL
          SELECT parent.id, parent.parent_container_id, parent.archived_at
          FROM containers parent
          JOIN chain child ON child.parent_container_id = parent.id
        )
        SELECT count(*) FILTER (WHERE archived_at IS NOT NULL), count(*)
        FROM chain
        """,
        [Ecto.UUID.dump!(container_id)]
      )

    case result.rows do
      [[0, total]] when total > 0 -> :ok
      _archived_or_missing -> {:error, :archived_container}
    end
  end

  @doc """
  Resolve a category id and require it to be active.
  """
  @spec require_active_category(String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found} | {:error, :archived_category}
  def require_active_category(nil), do: {:error, :not_found}

  def require_active_category(category_id) do
    case Ecto.UUID.cast(category_id) do
      :error -> {:error, :not_found}
      {:ok, id} -> check_category(id)
    end
  end

  defp check_category(id) do
    query =
      from(c in EquipmentCategory,
        where: c.id == ^id,
        select: %{archived_at: c.archived_at},
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %{archived_at: nil} -> {:ok, id}
      %{archived_at: _archived} -> {:error, :archived_category}
    end
  end
end
