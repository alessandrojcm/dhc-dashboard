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

    %Container{created_by: actor_id}
    |> container_changeset(normalized)
    |> Repo.insert()
    |> handle_container_insert()
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
        if circular_parent?(id, normalized) do
          {:error, :circular_parent}
        else
          container
          |> container_changeset(normalized)
          |> Repo.update()
          |> handle_container_update(id)
        end
    end
  end

  @spec delete_container(String.t()) ::
          {:ok, container()} | {:error, :not_found} | {:error, :still_referenced}
  def delete_container(id) when is_binary(id) do
    case Repo.get(Container, id) do
      nil ->
        {:error, :not_found}

      %Container{} = container ->
        delete_unreferenced_container(container)
    end
  end

  defp delete_unreferenced_container(%Container{} = container) do
    if direct_item_count(container.id) > 0 do
      {:error, :still_referenced}
    else
      case Repo.delete(container) do
        {:ok, deleted} -> {:ok, deleted}
        {:error, _changeset} -> {:error, :still_referenced}
      end
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

  defp container_changeset(%Container{} = container, attrs) do
    container
    |> Ecto.Changeset.cast(attrs, [:name, :description, :parent_container_id])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 100)
    |> Ecto.Changeset.validate_length(:description, max: 500)
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

  defp circular_parent?(container_id, normalized) do
    case Map.get(normalized, "parent_container_id") do
      nil -> false
      proposed when is_binary(proposed) -> cycle?(container_id, proposed)
    end
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
