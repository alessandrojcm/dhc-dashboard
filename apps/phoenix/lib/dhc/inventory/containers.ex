defmodule Dhc.Inventory.Containers do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.Container
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

    case parent_is_active(normalized) do
      :ok ->
        %Container{created_by: actor_id}
        |> container_changeset(normalized)
        |> Repo.insert()
        |> handle_container_insert()

      :archived_parent ->
        {:error, archived_parent_changeset(actor_id, normalized)}
    end
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
          {:ok, container()} | {:error, :not_found | :circular_parent | :archived_parent}
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
        "quantity" => i.quantity,
        "out_for_maintenance" => i.out_for_maintenance,
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

  defp parent_is_active(normalized) do
    case Map.get(normalized, "parent_container_id") do
      nil -> :ok
      parent_id -> if parent_chain_active?(parent_id), do: :ok, else: :archived_parent
    end
  end

  defp archived_parent_changeset(actor_id, attrs) do
    %Container{created_by: actor_id}
    |> container_changeset(attrs)
    |> Ecto.Changeset.add_error(:parent_container_id, "must refer to an active container")
  end

  defp cycle?(container_id, proposed) when proposed == container_id, do: true

  defp cycle?(container_id, proposed) do
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
        cond do
          parent_id == container.parent_container_id ->
            populate_flat_aggregates(container)

          parent_id != nil and not parent_chain_active?(parent_id) ->
            Repo.rollback(:archived_parent)

          parent_id != nil and cycle?(id, parent_id) ->
            Repo.rollback(:circular_parent)

          true ->
            container
            |> Ecto.Changeset.change(parent_container_id: parent_id)
            |> Repo.update!()
            |> populate_flat_aggregates()
        end
    end
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
          container
          |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
          |> Repo.update!()
          |> populate_flat_aggregates()
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
          container
          |> Ecto.Changeset.change(archived_at: nil)
          |> Repo.update!()
          |> populate_flat_aggregates()
        else
          Repo.rollback(:archived_parent)
        end
    end
  end

  defp translate_restore_result({:ok, %Container{} = container}), do: {:ok, container}
  defp translate_restore_result({:error, reason}), do: {:error, reason}

  defp active_dependants?(container_id) do
    %{rows: [[active_dependants?]]} =
      Repo.query!(
        """
        WITH RECURSIVE subtree AS (
          SELECT id FROM containers WHERE id = $1
          UNION ALL
          SELECT child.id
          FROM containers child
          JOIN subtree parent ON parent.id = child.parent_container_id
        )
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
        [Ecto.UUID.dump!(container_id)]
      )

    active_dependants?
  end

  defp lock_dependants(container_id) do
    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM containers WHERE id = $1
        UNION ALL
        SELECT child.id
        FROM containers child
        JOIN subtree parent ON parent.id = child.parent_container_id
      )
      SELECT container.id
      FROM containers container
      JOIN subtree ON subtree.id = container.id
      ORDER BY container.id
      FOR UPDATE
      """,
      [Ecto.UUID.dump!(container_id)]
    )

    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM containers WHERE id = $1
        UNION ALL
        SELECT child.id
        FROM containers child
        JOIN subtree parent ON parent.id = child.parent_container_id
      )
      SELECT item.id
      FROM inventory_items item
      JOIN subtree ON subtree.id = item.container_id
      ORDER BY item.id
      FOR UPDATE
      """,
      [Ecto.UUID.dump!(container_id)]
    )
  end

  defp parent_chain_active?(nil), do: true

  defp parent_chain_active?(parent_id) do
    %{rows: [[active?]]} =
      Repo.query!(
        """
        WITH RECURSIVE ancestors AS (
          SELECT id, parent_container_id, archived_at FROM containers WHERE id = $1
          UNION ALL
          SELECT parent.id, parent.parent_container_id, parent.archived_at
          FROM containers parent
          JOIN ancestors child ON child.parent_container_id = parent.id
        )
        SELECT EXISTS (SELECT 1 FROM ancestors)
          AND NOT EXISTS (SELECT 1 FROM ancestors WHERE archived_at IS NOT NULL)
        """,
        [Ecto.UUID.dump!(parent_id)]
      )

    active?
  end

  defp handle_container_insert({:ok, %Container{} = container}) do
    {:ok, populate_flat_aggregates(container)}
  end

  defp handle_container_insert({:error, %Ecto.Changeset{} = changeset}) do
    {:error, changeset}
  end

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
