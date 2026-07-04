defmodule Dhc.Inventory.Items do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemCursor
  alias Dhc.Inventory.ItemHistory
  alias Dhc.Repo

  @type item :: Item.t()

  @item_allowed_limits [10, 25, 50, 100]
  @item_default_limit 50

  @spec list_items(keyword() | map()) ::
          {:ok, %{items: [item()], limit: pos_integer, next_cursor: binary | nil}}
          | {:error, :invalid_limit | :bad_cursor}
  def list_items(opts \\ %{}) when is_map(opts) or is_list(opts) do
    opts = normalize_list_opts(opts)

    with :ok <- validate_limit(opts.limit),
         {:ok, cursor} <- ItemCursor.parse(opts.cursor, opts) do
      rows =
        item_base_query(opts)
        |> apply_cursor(cursor)
        |> limit(^Enum.min([opts.limit + 1, 101]))
        |> Repo.all()

      visible = Enum.take(rows, opts.limit)

      {:ok,
       %{
         items: Enum.map(visible, &load_item_aggregates/1),
         limit: opts.limit,
         next_cursor: ItemCursor.next(visible, rows, opts)
       }}
    end
  end

  @spec get_item(String.t()) :: {:ok, item()} | {:error, :not_found}
  def get_item(id) when is_binary(id) do
    case Repo.get(Item, id) do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, load_item_aggregates(item)}
    end
  end

  @spec create_item(map(), String.t()) ::
          {:ok, item()} | {:error, Ecto.Changeset.t()}
  def create_item(attrs, actor_id) when is_map(attrs) and is_binary(actor_id) do
    normalized = normalize_item_attrs(attrs)

    item_changeset =
      %Item{created_by: actor_id}
      |> item_changeset(normalized)
      |> Ecto.Changeset.foreign_key_constraint(:container_id,
        name: :inventory_items_container_id_fkey
      )
      |> Ecto.Changeset.foreign_key_constraint(:category_id,
        name: :inventory_items_category_id_fkey
      )
      |> Ecto.Changeset.foreign_key_constraint(:created_by,
        name: :inventory_items_created_by_fkey
      )

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:item, item_changeset)
    |> Ecto.Multi.insert(:history, fn %{item: %Item{} = item} ->
      ItemHistory.record_created_history(item, actor_id, Map.get(normalized, "notes"))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{item: %Item{} = item}} ->
        {:ok, load_item_aggregates(item)}

      {:error, :item, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, :history, _changeset, _changes} ->
        {:error, %Ecto.Changeset{errors: [history: {"could not record history", []}]}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @spec update_item(String.t(), map(), String.t()) ::
          {:ok, item()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_item(id, attrs, actor_id)
      when is_binary(id) and is_map(attrs) and is_binary(actor_id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        normalized = normalize_item_attrs(attrs)
        old_container_id = item.container_id
        new_container_id = Map.get(normalized, "container_id", old_container_id)

        changeset =
          item
          |> item_changeset(normalized)
          |> Ecto.Changeset.put_change(:updated_by, actor_id)
          |> Ecto.Changeset.foreign_key_constraint(:container_id,
            name: :inventory_items_container_id_fkey
          )
          |> Ecto.Changeset.foreign_key_constraint(:category_id,
            name: :inventory_items_category_id_fkey
          )
          |> Ecto.Changeset.foreign_key_constraint(:updated_by,
            name: :inventory_items_updated_by_fkey
          )

        multi = Ecto.Multi.new() |> Ecto.Multi.update(:item, changeset)

        multi =
          if container_changed?(old_container_id, new_container_id) do
            Ecto.Multi.insert(
              multi,
              :history_moved,
              ItemHistory.record_moved_history(
                item.id,
                old_container_id,
                new_container_id,
                actor_id,
                Map.get(normalized, "notes")
              )
            )
          else
            multi
          end

        multi =
          Ecto.Multi.insert(multi, :history_updated, fn %{item: %Item{}} ->
            ItemHistory.record_updated_history(item.id, actor_id, Map.get(normalized, "notes"))
          end)

        multi
        |> Repo.transaction()
        |> case do
          {:ok, %{item: %Item{} = updated}} ->
            {:ok, load_item_aggregates(updated)}

          {:error, :item, %Ecto.Changeset{} = err, _changes} ->
            {:error, err}

          {:error, _step, %Ecto.Changeset{} = err, _changes} ->
            {:error, err}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  @spec delete_item(String.t()) :: {:ok, item()} | {:error, :not_found}
  def delete_item(id) when is_binary(id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        case Repo.delete(item) do
          {:ok, deleted} -> {:ok, deleted}
          {:error, _changeset} -> {:error, :not_found}
        end
    end
  end

  defp item_base_query(opts) do
    from(i in Item,
      order_by: [desc: i.created_at, desc: i.id],
      select: i
    )
    |> maybe_filter(:category_id, opts.category_id)
    |> maybe_filter(:container_id, opts.container_id)
    |> maybe_filter_maintenance(opts.out_for_maintenance)
    |> maybe_search(opts.search)
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    where(query, [i], field(i, ^field) == ^value)
  end

  defp maybe_filter_maintenance(query, nil), do: query

  defp maybe_filter_maintenance(query, value) when is_boolean(value) do
    where(query, [i], i.out_for_maintenance == ^value)
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) when is_binary(search) do
    pattern = "%#{String.downcase(search)}%"

    from(i in query,
      left_join: c in Container,
      on: c.id == i.container_id,
      left_join: cat in EquipmentCategory,
      on: cat.id == i.category_id,
      where:
        fragment("COALESCE(LOWER(?), '') ILIKE ?", i.notes, ^pattern) or
          fragment("COALESCE(LOWER(?), '') ILIKE ?", cat.name, ^pattern) or
          fragment("COALESCE(LOWER(?), '') ILIKE ?", c.name, ^pattern)
    )
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, %{created_at: created_at, id: id}) do
    where(
      query,
      [i],
      i.created_at < ^created_at or (i.created_at == ^created_at and i.id < ^id)
    )
  end

  defp normalize_list_opts(opts) when is_map(opts) do
    %{
      limit: parse_integer(Map.get(opts, "limit"), @item_default_limit),
      cursor: blank_to_nil(Map.get(opts, "cursor")),
      category_id: blank_to_nil(Map.get(opts, "categoryId") || Map.get(opts, "category_id")),
      container_id: blank_to_nil(Map.get(opts, "containerId") || Map.get(opts, "container_id")),
      out_for_maintenance:
        parse_bool(Map.get(opts, "outForMaintenance") || Map.get(opts, "out_for_maintenance")),
      search: blank_to_nil(Map.get(opts, "search"))
    }
  end

  defp normalize_list_opts(opts) when is_list(opts) do
    normalize_list_opts(Map.new(opts))
  end

  defp parse_integer(nil, default), do: default
  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_bool(nil), do: nil
  defp parse_bool(true), do: true
  defp parse_bool(false), do: false

  defp parse_bool(value) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp validate_limit(limit) when limit in @item_allowed_limits, do: :ok
  defp validate_limit(_), do: {:error, :invalid_limit}

  defp load_item_aggregates(%Item{} = item) do
    %Item{
      item
      | container: container_summary(item.container_id),
        category: category_summary(item.category_id)
    }
  end

  defp container_summary(nil), do: nil

  defp container_summary(container_id) do
    from(c in Container,
      where: c.id == ^container_id,
      select: %{"id" => c.id, "name" => c.name, "parent_container_id" => c.parent_container_id}
    )
    |> Repo.one()
  end

  defp category_summary(nil), do: nil

  defp category_summary(category_id) do
    from(c in EquipmentCategory,
      where: c.id == ^category_id,
      select: %{"id" => c.id, "name" => c.name}
    )
    |> Repo.one()
  end

  defp item_changeset(%Item{} = item, attrs) do
    item
    |> Ecto.Changeset.cast(attrs, [
      :container_id,
      :category_id,
      :attributes,
      :quantity,
      :notes,
      :out_for_maintenance,
      :photo_url
    ])
    |> Ecto.Changeset.validate_required([:container_id, :category_id, :quantity])
    |> Ecto.Changeset.validate_number(:quantity, greater_than: 0)
    |> Ecto.Changeset.validate_length(:notes, max: 1000)
  end

  defp normalize_item_attrs(attrs) when is_map(attrs) do
    [
      {"container_id", ["containerId", "container_id", :container_id, :containerId]},
      {"category_id", ["categoryId", "category_id", :category_id, :categoryId]},
      {"quantity", ["quantity", :quantity]},
      {"notes", ["notes", :notes]},
      {"out_for_maintenance",
       ["outForMaintenance", "out_for_maintenance", :out_for_maintenance, :outForMaintenance]},
      {"photo_url", ["photoUrl", "photo_url", :photo_url, :photoUrl]},
      {"attributes", ["attributes", :attributes]}
    ]
    |> Enum.reduce(%{}, fn {dest, sources}, acc ->
      case take_index_value(attrs, sources) do
        :absent -> acc
        value -> Map.put(acc, dest, value)
      end
    end)
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

  defp container_changed?(nil, nil), do: false
  defp container_changed?(a, b) when a == b, do: false
  defp container_changed?(_old, _new), do: true
end
