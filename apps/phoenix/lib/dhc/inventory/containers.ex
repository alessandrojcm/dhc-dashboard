defmodule Dhc.Inventory.Containers do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Repo

  @type container :: Container.t()

  @spec list_containers() :: [container()]
  def list_containers do
    counts_query =
      from(i in "inventory_items",
        where: i.container_id == parent_as(:c0).id,
        select: count(i.id)
      )

    from(c in Container,
      as: :c0,
      left_join: p in Container,
      on: p.id == c.parent_container_id,
      order_by: [asc: c.name],
      select_merge: %{
        item_count: subquery(counts_query),
        parent_container:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?, 'name', ?) ELSE NULL END",
            c.parent_container_id,
            p.id,
            p.name
          )
      }
    )
    |> Repo.all()
  end

  @spec get_container(String.t()) :: {:ok, container()} | {:error, :not_found}
  def get_container(id) when is_binary(id) do
    case Repo.get(Container, id) do
      nil -> {:error, :not_found}
      %Container{} = container -> {:ok, load_container_relations(container)}
    end
  end

  @spec create_container(map(), String.t()) ::
          {:ok, container()} | {:error, Ecto.Changeset.t()}
  def create_container(attrs, actor_id) when is_map(attrs) and is_binary(actor_id) do
    normalized = normalize_container_attrs(attrs)

    Repo.transaction(fn -> insert_created_container(actor_id, normalized) end)
  end

  @spec update_container(String.t(), map()) ::
          {:ok, container()}
          | {:error, :not_found}
          | {:error, :circular_parent}
          | {:error, Ecto.Changeset.t()}
  def update_container(id, attrs) when is_binary(id) and is_map(attrs) do
    normalized = normalize_container_attrs(attrs)

    case Repo.get(Container, id) do
      nil ->
        {:error, :not_found}

      %Container{} = container ->
        update_existing_container(container, normalized)
    end
  end

  @spec move_container(String.t(), String.t() | nil) ::
          {:ok, container()}
          | {:error, :not_found | :circular_parent | :archived_parent}
          | {:error, Ecto.Changeset.t()}
  def move_container(id, parent_container_id) when is_binary(id) do
    Repo.transaction(fn ->
      locked_move_container(id, normalize_parent_id(parent_container_id))
    end)
    |> translate_move_result()
  end

  @spec archive_container(String.t()) ::
          {:ok, container()} | {:error, :not_found | :active_dependants}
  def archive_container(id) when is_binary(id) do
    Repo.transaction(fn -> locked_archive_container(id) end)
    |> translate_archive_result()
  end

  @spec restore_container(String.t()) ::
          {:ok, container()} | {:error, :not_found | :archived_parent}
  def restore_container(id) when is_binary(id) do
    Repo.transaction(fn -> locked_restore_container(id) end)
    |> translate_restore_result()
  end

  @spec delete_container(String.t()) ::
          {:ok, container()} | {:error, :not_found} | {:error, :still_referenced}
  def delete_container(id) when is_binary(id) do
    Repo.transaction(fn -> locked_delete_container(id) end)
    |> translate_delete_result()
  end

  defp locked_delete_container(id) do
    case Repo.get(Container, id, lock: "FOR UPDATE") do
      nil -> Repo.rollback(:not_found)
      %Container{} = container -> delete_unreferenced_container(container)
    end
  end

  defp delete_unreferenced_container(%Container{} = container) do
    lock_dependants(container.id)

    if direct_dependants?(container.id) do
      Repo.rollback(:still_referenced)
    else
      case Repo.delete(container) do
        {:ok, deleted} -> deleted
        {:error, _changeset} -> Repo.rollback(:still_referenced)
      end
    end
  end

  defp translate_delete_result({:ok, %Container{} = container}), do: {:ok, container}
  defp translate_delete_result({:error, reason}), do: {:error, reason}

  defp update_existing_container(%Container{} = container, normalized) do
    case Map.fetch(normalized, "parent_container_id") do
      :error ->
        container
        |> container_changeset(normalized)
        |> Repo.update()
        |> handle_container_update(container.id)

      {:ok, parent_id} ->
        move_and_update(container.id, parent_id, normalized)
        |> translate_move_result()
    end
  end

  defp move_and_update(id, parent_id, normalized) do
    Repo.transaction(fn ->
      id
      |> locked_move_container(parent_id)
      |> update_moved_container(normalized)
    end)
  end

  defp update_moved_container(%Container{} = container, normalized) do
    case container
         |> container_changeset(Map.delete(normalized, "parent_container_id"))
         |> Repo.update() do
      {:ok, updated} -> populate_flat_aggregates(updated)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp load_container_relations(%Container{} = container) do
    items = list_container_items(container.id)

    %Container{
      container
      | parent_container: parent_summary(container.parent_container_id),
        child_containers: list_child_summaries(container.id),
        items: items,
        item_count: length(items)
    }
  end

  defp parent_summary(nil), do: nil

  defp parent_summary(parent_id) do
    case Repo.get(Container, parent_id) do
      nil -> nil
      %Container{} = p -> %{"id" => p.id, "name" => p.name}
    end
  end

  defp list_child_summaries(parent_id) do
    from(c in Container,
      where: c.parent_container_id == ^parent_id,
      order_by: [asc: c.name],
      select: %{"id" => c.id, "name" => c.name}
    )
    |> Repo.all()
  end

  defp list_container_items(container_id) do
    from(i in "inventory_items",
      left_join: cat in "equipment_categories",
      on: cat.id == i.category_id,
      where: i.container_id == type(^container_id, :binary_id),
      order_by: [asc: i.created_at],
      select: %{
        "id" => fragment("?::text", i.id),
        "category" =>
          fragment(
            "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
            cat.id,
            cat.id,
            cat.name
          )
      }
    )
    |> Repo.all()
  end

  defp direct_item_count(container_id) do
    from(i in "inventory_items",
      where: i.container_id == type(^container_id, :binary_id),
      select: count(i.id)
    )
    |> Repo.one() || 0
  end

  defp direct_dependants?(container_id) do
    children? =
      from(c in Container, where: c.parent_container_id == ^container_id)
      |> Repo.exists?()

    children? or direct_item_count(container_id) > 0
  end

  defp container_changeset(%Container{} = container, attrs) do
    container
    |> Ecto.Changeset.cast(attrs, [:name, :description, :parent_container_id])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 100)
    |> Ecto.Changeset.validate_length(:description, max: 500)
    |> Ecto.Changeset.unique_constraint(:name, name: :containers_root_name_unique)
    |> Ecto.Changeset.unique_constraint(:name, name: :containers_sibling_name_unique)
    |> Ecto.Changeset.foreign_key_constraint(:parent_container_id,
      name: :containers_parent_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:created_by, name: :containers_created_by_fkey)
  end

  defp normalize_container_attrs(attrs) when is_map(attrs) do
    normalized =
      [
        {"name", [:name, "name"]},
        {"description", [:description, "description"]}
      ]
      |> Enum.reduce(%{}, fn {dest, sources}, acc ->
        case take_index_value(attrs, sources) do
          :absent -> acc
          value -> Map.put(acc, dest, value)
        end
      end)

    case take_index_value(attrs, [
           "parentContainerId",
           "parent_container_id",
           :parentContainerId,
           :parent_container_id
         ]) do
      :absent -> normalized
      value -> Map.put(normalized, "parent_container_id", normalize_parent_id(value))
    end
  end

  defp take_index_value(attrs, sources) do
    Enum.find_value(sources, :__absent__, fn key ->
      if is_map_key(attrs, key), do: {:present, Map.get(attrs, key)}, else: nil
    end)
    |> case do
      :__absent__ -> :absent
      {:present, value} -> value
    end
  end

  defp normalize_parent_id(nil), do: nil
  defp normalize_parent_id(""), do: nil
  defp normalize_parent_id(value) when is_binary(value), do: value
  defp normalize_parent_id(value), do: value

  defp insert_created_container(actor_id, normalized) do
    changeset = %Container{created_by: actor_id} |> container_changeset(normalized)

    cond do
      invalid_parent_id?(Map.get(normalized, "parent_container_id")) ->
        Repo.rollback(invalid_parent_changeset(%Container{created_by: actor_id}))

      not changeset.valid? ->
        Repo.rollback(changeset)

      parent_is_active(normalized) == :archived_parent ->
        Repo.rollback(archived_parent_changeset(actor_id, normalized))

      true ->
        case Repo.insert(changeset) do
          {:ok, container} -> populate_flat_aggregates(container)
          {:error, failed} -> Repo.rollback(failed)
        end
    end
  end

  defp parent_is_active(normalized) do
    case Map.get(normalized, "parent_container_id") do
      nil ->
        :ok

      parent_id ->
        case ItemGuards.require_active_container_chain(parent_id) do
          :ok -> :ok
          {:error, _reason} -> :archived_parent
        end
    end
  end

  defp archived_parent_changeset(actor_id, attrs) do
    %Container{created_by: actor_id}
    |> container_changeset(attrs)
    |> Ecto.Changeset.add_error(:parent_container_id, "must refer to an active container")
  end

  defp cycle?(container_id, proposed) do
    if skip_cycle_check?() do
      false
    else
      detect_cycle?(container_id, proposed)
    end
  end

  defp skip_cycle_check? do
    :dhc
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:skip_cycle_check, false)
  end

  defp detect_cycle?(container_id, proposed) when proposed == container_id, do: true

  defp detect_cycle?(container_id, proposed) do
    parent_map = container_parent_map()

    Stream.unfold(proposed, fn
      nil -> nil
      current -> {current, Map.get(parent_map, current)}
    end)
    |> Enum.reduce_while(false, fn
      ^container_id, _acc -> {:halt, true}
      nil, _acc -> {:halt, false}
      _id, _acc -> {:cont, false}
    end)
  end

  defp container_parent_map do
    from(c in Container, select: {c.id, c.parent_container_id})
    |> Repo.all()
    |> Map.new()
  end

  defp locked_move_container(id, parent_id) do
    case Repo.get(Container, id, lock: "FOR UPDATE") do
      nil ->
        Repo.rollback(:not_found)

      %Container{} = container ->
        apply_locked_move(container, parent_id)
    end
  end

  defp apply_locked_move(%Container{} = container, parent_id) do
    changeset = move_changeset(container, parent_id)

    cond do
      parent_id == container.parent_container_id ->
        populate_flat_aggregates(container)

      invalid_parent_id?(parent_id) ->
        Repo.rollback(invalid_parent_changeset(container))

      not changeset.valid? ->
        Repo.rollback(changeset)

      parent_id != nil and not parent_chain_active?(parent_id) ->
        Repo.rollback(:archived_parent)

      parent_id != nil and cycle?(container.id, parent_id) ->
        Repo.rollback(:circular_parent)

      true ->
        persist_moved_container(changeset)
    end
  end

  defp invalid_parent_id?(nil), do: false

  defp invalid_parent_id?(parent_id) when is_binary(parent_id) do
    match?(:error, Ecto.UUID.cast(parent_id))
  end

  defp invalid_parent_id?(_parent_id), do: true

  defp invalid_parent_changeset(%Container{} = container) do
    container
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:parent_container_id, "is invalid")
  end

  defp move_changeset(%Container{} = container, parent_id) do
    container
    |> Ecto.Changeset.cast(%{"parent_container_id" => parent_id}, [:parent_container_id])
    |> Ecto.Changeset.unique_constraint(:name, name: :containers_root_name_unique)
    |> Ecto.Changeset.unique_constraint(:name, name: :containers_sibling_name_unique)
    |> Ecto.Changeset.check_constraint(:parent_container_id, name: :containers_parent_acyclic)
    |> Ecto.Changeset.foreign_key_constraint(:parent_container_id,
      name: :containers_parent_container_id_fkey
    )
  end

  defp persist_moved_container(%Ecto.Changeset{} = changeset) do
    # The acyclic trigger is DEFERRABLE INITIALLY DEFERRED, so without this
    # it would fire at COMMIT — after Repo.update/1 already returned :ok —
    # and escape as a Postgrex.Error. Immediate checking makes the
    # check_constraint/3 translation on the changeset actually run.
    Repo.query!("SET CONSTRAINTS containers_parent_acyclic IMMEDIATE")

    case Repo.update(changeset) do
      {:ok, updated} -> populate_flat_aggregates(updated)
      {:error, failed} -> Repo.rollback(translate_move_write_error(failed))
    end
  end

  defp translate_move_write_error(%Ecto.Changeset{} = changeset) do
    if cycle_constraint?(changeset), do: :circular_parent, else: changeset
  end

  defp cycle_constraint?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:parent_container_id, {_msg, meta}} ->
        Keyword.get(meta, :constraint) == :check and
          Keyword.get(meta, :constraint_name) == "containers_parent_acyclic"

      _other ->
        false
    end)
  end

  defp translate_move_result({:ok, %Container{} = container}), do: {:ok, container}
  defp translate_move_result({:error, reason}), do: {:error, reason}

  defp locked_archive_container(id) do
    case Repo.get(Container, id, lock: "FOR UPDATE") do
      nil ->
        Repo.rollback(:not_found)

      %Container{archived_at: archived_at} = container when not is_nil(archived_at) ->
        populate_flat_aggregates(container)

      %Container{} = container ->
        lock_dependants(container.id)

        if active_dependants?(container.id) do
          Repo.rollback(:active_dependants)
        else
          persist_container_stamp(container, archived_at: DateTime.utc_now())
        end
    end
  end

  defp translate_archive_result({:ok, %Container{} = container}), do: {:ok, container}
  defp translate_archive_result({:error, reason}), do: {:error, reason}

  defp locked_restore_container(id) do
    case Repo.get(Container, id, lock: "FOR UPDATE") do
      nil ->
        Repo.rollback(:not_found)

      %Container{archived_at: nil} = container ->
        populate_flat_aggregates(container)

      %Container{} = container ->
        if parent_chain_active?(container.parent_container_id) do
          persist_container_stamp(container, archived_at: nil)
        else
          Repo.rollback(:archived_parent)
        end
    end
  end

  defp persist_container_stamp(%Container{} = container, changes) do
    case container |> Ecto.Changeset.change(changes) |> Repo.update() do
      {:ok, updated} -> populate_flat_aggregates(updated)
      {:error, _failed} -> Repo.rollback(:not_found)
    end
  end

  defp translate_restore_result({:ok, %Container{} = container}), do: {:ok, container}
  defp translate_restore_result({:error, reason}), do: {:error, reason}

  defp active_dependants?(container_id) do
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

  defp lock_dependants(container_id) do
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
  end

  # Shared recursive walk of a container and every descendant. The three
  # callers differ only in the SELECT that follows (active-dependant check,
  # container FOR UPDATE, item FOR UPDATE).
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

  defp parent_chain_active?(parent_id), do: ItemGuards.container_chain_active?(parent_id)

  defp handle_container_update({:ok, %Container{} = container}, id) do
    case Repo.get(Container, id) do
      nil -> {:ok, populate_flat_aggregates(container)}
      %Container{} = fresh -> {:ok, populate_flat_aggregates(fresh)}
    end
  end

  defp handle_container_update({:error, %Ecto.Changeset{} = changeset}, _id) do
    {:error, changeset}
  end

  defp populate_flat_aggregates(%Container{} = container) do
    %Container{
      container
      | item_count: direct_item_count(container.id),
        parent_container: parent_summary(container.parent_container_id)
    }
  end
end
