defmodule Dhc.Inventory.Categories do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Repo

  @type category :: EquipmentCategory.t()

  @spec list_categories() :: [category()]
  def list_categories do
    counts_query =
      from(i in "inventory_items",
        where: i.category_id == parent_as(:c0).id,
        select: count(i.id)
      )

    from(c in EquipmentCategory,
      as: :c0,
      order_by: [asc: c.name],
      select_merge: %{item_count: subquery(counts_query)}
    )
    |> Repo.all()
  end

  @spec get_category(String.t()) :: {:ok, category()} | {:error, :not_found}
  def get_category(id) when is_binary(id) do
    counts_query =
      from(i in "inventory_items",
        where: i.category_id == type(^id, :binary_id),
        select: count(i.id)
      )

    case from(c in EquipmentCategory,
           where: c.id == ^id,
           select_merge: %{item_count: subquery(counts_query)}
         )
         |> Repo.one() do
      nil -> {:error, :not_found}
      %EquipmentCategory{} = category -> {:ok, category}
    end
  end

  @spec create_category(map()) ::
          {:ok, category()}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def create_category(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    %EquipmentCategory{}
    |> category_changeset(normalized)
    |> Repo.insert()
    |> handle_insert_result()
  end

  @spec update_category(category() | String.t(), map(), keyword()) ::
          {:ok, category()}
          | {:error, :not_found}
          | {:error, {:version_precondition_failed, category()}}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def update_category(category_or_id, attrs, opts \\ [])

  def update_category(%EquipmentCategory{id: id}, attrs, opts),
    do: update_category(id, attrs, opts)

  def update_category(id, attrs, opts)
      when is_binary(id) and is_map(attrs) and is_list(opts) do
    case Repo.get(EquipmentCategory, id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} = category ->
        case check_precondition(category, opts) do
          :ok ->
            update_existing_category(category, attrs)

          {:version_precondition_failed, current} ->
            {:error, {:version_precondition_failed, current}}
        end
    end
  end

  @spec delete_category(category() | String.t(), keyword()) ::
          {:ok, category()}
          | {:error, :not_found}
          | {:error, {:version_precondition_failed, category()}}
          | {:error, :still_referenced}
  def delete_category(category_or_id, opts \\ [])

  def delete_category(%EquipmentCategory{id: id}, opts), do: delete_category(id, opts)

  def delete_category(id, opts) when is_binary(id) and is_list(opts) do
    case Repo.get(EquipmentCategory, id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} = category ->
        case check_precondition(category, opts) do
          :ok ->
            delete_unreferenced_category(category)

          {:version_precondition_failed, current} ->
            {:error, {:version_precondition_failed, current}}
        end
    end
  end

  # If-Match precondition check — ADR 0023 (ALE-267). Absent or `*` passes;
  # a version mismatch fails fast without applying any changes.
  defp check_precondition(%EquipmentCategory{} = category, opts) do
    case Keyword.fetch(opts, :expected_lock_version) do
      :error ->
        :ok

      {:ok, :*} ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        if category.lock_version == expected,
          do: :ok,
          else: {:version_precondition_failed, category}

      {:ok, expected_versions} when is_list(expected_versions) ->
        if category.lock_version in expected_versions,
          do: :ok,
          else: {:version_precondition_failed, category}
    end
  end

  defp update_existing_category(%EquipmentCategory{} = category, attrs) do
    normalized = normalize_attrs(attrs)

    result =
      category
      |> category_changeset(normalized)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update(stale_error_field: :lock_version)

    case result do
      {:error, changeset} ->
        if stale_changeset?(changeset),
          do: current_category_error(category.id),
          else: handle_update_result(result)

      result ->
        handle_update_result(result)
    end
  end

  defp category_changeset(%EquipmentCategory{} = category, attrs) do
    category
    |> Ecto.Changeset.cast(attrs, [:name, :description, :available_attributes])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 50)
    |> Ecto.Changeset.validate_length(:description, max: 500)
    |> validate_available_attributes()
    |> Ecto.Changeset.unique_constraint(:name, name: :equipment_categories_name_index)
  end

  defp validate_available_attributes(changeset) do
    case Ecto.Changeset.get_change(changeset, :available_attributes) do
      nil ->
        changeset

      list when is_list(list) ->
        case Enum.find_value(list, &available_attribute_error/1) do
          nil -> changeset
          message -> Ecto.Changeset.add_error(changeset, :available_attributes, message)
        end

      _ ->
        Ecto.Changeset.add_error(changeset, :available_attributes, "must be an array")
    end
  end

  defp delete_unreferenced_category(%EquipmentCategory{} = category) do
    if category_item_count(category.id) > 0 do
      {:error, :still_referenced}
    else
      changeset = Ecto.Changeset.optimistic_lock(category, :lock_version)

      case Repo.delete(changeset, stale_error_field: :lock_version) do
        {:ok, deleted} ->
          {:ok, deleted}

        # A concurrent edit bumped the version between read and delete; Ecto
        # returns an explicitly marked changeset error when stale_error_field
        # is set. Map it to the same failure the checked path sees.
        {:error, changeset} ->
          handle_category_delete_error(changeset, category.id)
      end
    end
  end

  defp handle_category_delete_error(changeset, id) do
    if stale_changeset?(changeset), do: current_category_error(id), else: {:error, :not_found}
  end

  defp current_category_error(id) do
    case get_category(id) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, current} -> {:error, {:version_precondition_failed, current}}
    end
  end

  defp category_item_count(id) do
    from(i in "inventory_items",
      where: i.category_id == type(^id, :binary_id),
      select: count(i.id)
    )
    |> Repo.one() || 0
  end

  defp available_attribute_error(item) when not is_map(item),
    do: "must be an array of attribute definitions"

  defp available_attribute_error(%{"type" => type})
       when type not in ~w(text select number boolean),
       do: "attribute type must be one of: text, select, number, boolean"

  defp available_attribute_error(_item), do: nil

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      "name" => map_get(attrs, [:name, "name"]),
      "description" => map_get(attrs, [:description, "description"]),
      "available_attributes" =>
        map_get(attrs, [:available_attributes, "available_attributes", "availableAttributes"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp map_get(map, keys) do
    Enum.find_value(keys, fn
      key when is_atom(key) -> Map.get(map, key)
      key when is_binary(key) -> Map.get(map, key)
    end)
  end

  defp handle_insert_result({:ok, %EquipmentCategory{} = category}) do
    {:ok, %EquipmentCategory{category | item_count: 0}}
  end

  defp handle_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if conflict?(changeset), do: {:error, :conflict, changeset}, else: {:error, changeset}
  end

  defp handle_update_result({:ok, %EquipmentCategory{} = category}) do
    item_count =
      from(i in "inventory_items",
        where: i.category_id == type(^category.id, :binary_id),
        select: count(i.id)
      )
      |> Repo.one() || 0

    {:ok, %EquipmentCategory{category | item_count: item_count}}
  end

  defp handle_update_result({:error, %Ecto.Changeset{} = changeset}) do
    if conflict?(changeset), do: {:error, :conflict, changeset}, else: {:error, changeset}
  end

  defp stale_changeset?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:lock_version, {_, [stale: true]}} -> true
      _ -> false
    end)
  end

  defp conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {"has already been taken", _}} -> true
      _ -> false
    end)
  end
end
