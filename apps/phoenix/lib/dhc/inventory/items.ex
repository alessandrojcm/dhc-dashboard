defmodule Dhc.Inventory.Items do
  @moduledoc false

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.Container
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemHistory
  alias Dhc.Repo

  @type item :: Item.t()

  @item_allowed_limits [10, 25, 50, 100]
  @item_default_limit 50
  @item_sort_specs %{
    "createdAt" => %{field: :created_at, type: :utc_datetime, encode: &DateTime.to_iso8601/1}
  }

  @spec list_items(keyword() | map()) ::
          {:ok, %{items: [item()], limit: pos_integer, next_cursor: binary | nil}}
          | {:error, :invalid_limit | :bad_cursor}
  def list_items(opts \\ %{}) when is_map(opts) or is_list(opts) do
    opts = normalize_list_opts(opts)

    with :ok <- validate_limit(opts.limit),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &item_cursor_context/1) do
      rows =
        item_base_query(opts)
        |> CursorPagination.apply_cursor(
          cursor,
          Map.merge(opts, %{sort: "createdAt", direction: "desc"}),
          @item_sort_specs
        )
        |> CursorPagination.apply_order(:created_at, "desc")
        |> limit(^Enum.min([opts.limit + 1, 101]))
        |> Repo.all()

      page =
        CursorPagination.forward_page(rows, opts, &item_cursor_context/1, &item_cursor_value/2)

      {:ok,
       %{
         items: Enum.map(page.visible_rows, &load_item_aggregates/1),
         limit: opts.limit,
         next_cursor: page.next_cursor
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
        update_existing_item(item, attrs, actor_id)
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

  @doc """
  Move an item to a different container — ALE-108 dedicated command.

  Updates `container_id` and `updated_by`, records a `moved` history row with
  old/new container ids and optional notes. General edits (quantity, notes,
  attributes, maintenance) are not part of this command; use `update_item/3`.
  """
  @spec move_item(String.t(), map(), String.t()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :invalid_container}
          | {:error, Ecto.Changeset.t()}
  def move_item(id, attrs, actor_id)
      when is_binary(id) and is_map(attrs) and is_binary(actor_id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        move_existing_item(item, attrs, actor_id)
    end
  end

  @doc """
  Toggle an item's maintenance flag — ALE-108 dedicated command.

  Sets `out_for_maintenance`, sets `updated_by`, and records a `maintenance_out`
  (when the flag goes to `true`) or `maintenance_in` (when `false`) history row
  with optional notes.
  """
  @spec set_item_maintenance(String.t(), map(), String.t()) ::
          {:ok, item()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def set_item_maintenance(id, attrs, actor_id)
      when is_binary(id) and is_map(attrs) and is_binary(actor_id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        set_existing_item_maintenance(item, attrs, actor_id)
    end
  end

  defp update_existing_item(%Item{} = item, attrs, actor_id) do
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
      |> Ecto.Changeset.optimistic_lock(:lock_version)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:item, changeset)
    |> maybe_record_move(item, new_container_id, actor_id, Map.get(normalized, "notes"))
    |> Ecto.Multi.insert(:history_updated, fn %{item: %Item{}} ->
      ItemHistory.record_updated_history(item.id, actor_id, Map.get(normalized, "notes"))
    end)
    |> Repo.transaction()
    |> handle_item_transaction()
  end

  defp move_existing_item(%Item{} = item, attrs, actor_id) do
    new_container_id = parse_container_id(attrs)

    changeset =
      item
      |> Ecto.Changeset.cast(%{container_id: new_container_id}, [:container_id])
      |> Ecto.Changeset.validate_required([:container_id])
      |> Ecto.Changeset.put_change(:updated_by, actor_id)
      |> Ecto.Changeset.foreign_key_constraint(:container_id,
        name: :inventory_items_container_id_fkey
      )
      |> Ecto.Changeset.foreign_key_constraint(:updated_by,
        name: :inventory_items_updated_by_fkey
      )
      |> Ecto.Changeset.optimistic_lock(:lock_version)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:item, changeset)
    |> maybe_record_move(item, new_container_id, actor_id, parse_notes(attrs))
    |> Repo.transaction()
    |> handle_move_transaction()
  end

  defp set_existing_item_maintenance(%Item{} = item, attrs, actor_id) do
    case parse_maintenance_flag(attrs) do
      {:ok, out_for_maintenance} ->
        update_maintenance(item, out_for_maintenance, actor_id, parse_notes(attrs))

      :invalid ->
        {:error, %Ecto.Changeset{errors: [out_for_maintenance: {"is invalid", []}]}}
    end
  end

  defp update_maintenance(item, out_for_maintenance, actor_id, notes) do
    changeset =
      item
      |> Ecto.Changeset.cast(%{out_for_maintenance: out_for_maintenance}, [
        :out_for_maintenance
      ])
      |> Ecto.Changeset.put_change(:updated_by, actor_id)
      |> Ecto.Changeset.foreign_key_constraint(:updated_by,
        name: :inventory_items_updated_by_fkey
      )
      |> Ecto.Changeset.optimistic_lock(:lock_version)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:item, changeset)
    |> maybe_record_maintenance(item, out_for_maintenance, actor_id, notes)
    |> Repo.transaction()
    |> handle_item_transaction()
  end

  defp maybe_record_move(multi, item, new_container_id, actor_id, notes) do
    if container_changed?(item.container_id, new_container_id) do
      Ecto.Multi.insert(
        multi,
        :history_moved,
        ItemHistory.record_moved_history(
          item.id,
          item.container_id,
          new_container_id,
          actor_id,
          notes
        )
      )
    else
      multi
    end
  end

  defp maybe_record_maintenance(multi, item, out_for_maintenance, actor_id, notes) do
    if item.out_for_maintenance != out_for_maintenance do
      Ecto.Multi.insert(
        multi,
        :history_maintenance,
        ItemHistory.record_maintenance_history(item.id, out_for_maintenance, actor_id, notes)
      )
    else
      multi
    end
  end

  defp handle_item_transaction({:ok, %{item: %Item{} = updated}}),
    do: {:ok, load_item_aggregates(updated)}

  defp handle_item_transaction({:error, _step, %Ecto.Changeset{} = err, _changes}),
    do: {:error, err}

  defp handle_item_transaction({:error, _step, reason, _changes}), do: {:error, reason}

  defp handle_move_transaction(
         {:error, :item, %Ecto.Changeset{errors: [{:container_id, _} | _]}, _changes}
       ),
       do: {:error, :invalid_container}

  defp handle_move_transaction(result), do: handle_item_transaction(result)

  defp item_base_query(opts) do
    from(i in Item,
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

  defp item_cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => "createdAt",
      "direction" => "desc",
      "categoryId" => opts.category_id,
      "containerId" => opts.container_id,
      "outForMaintenance" => opts.out_for_maintenance,
      "search" => opts.search
    }
  end

  defp item_cursor_value(row, _opts), do: DateTime.to_iso8601(row.created_at)

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
    |> Ecto.Changeset.validate_number(:quantity,
      greater_than: 0,
      less_than_or_equal_to: 1_000_000
    )
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

  # ── move/maintenance command body parsing (ALE-108) ─────────────────

  defp parse_container_id(attrs) do
    take_first(attrs, ["containerId", "container_id"])
  end

  defp parse_notes(attrs) do
    case take_first(attrs, ["notes"]) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_maintenance_flag(attrs) do
    # `outForMaintenance` is contract-required on the maintenance body; nil
    # (missing or null) maps to :invalid → 422. Don't use `||` — `false` is
    # falsy in Elixir and would wrongly fall through.
    case take_first(attrs, ["outForMaintenance", "out_for_maintenance"]) do
      true -> {:ok, true}
      false -> {:ok, false}
      _ -> :invalid
    end
  end

  defp take_first(attrs, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end
end
