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

  @spec update_category(category() | String.t(), map()) ::
          {:ok, category()}
          | {:error, :not_found}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def update_category(%EquipmentCategory{id: id}, attrs), do: update_category(id, attrs)

  def update_category(id, attrs) when is_binary(id) do
    case Repo.get(EquipmentCategory, id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} = category ->
        normalized = normalize_attrs(attrs)

        category
        |> category_changeset(normalized)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
        |> handle_update_result()
    end
  end

  @spec delete_category(category() | String.t()) ::
          {:ok, category()} | {:error, :not_found} | {:error, :still_referenced}
  def delete_category(%EquipmentCategory{id: id}), do: delete_category(id)

  def delete_category(id) when is_binary(id) do
    case Repo.get(EquipmentCategory, id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} = category ->
        delete_unreferenced_category(category)
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

  defp delete_unreferenced_category(%EquipmentCategory{id: id} = category) do
    if category_item_count(id) > 0 do
      {:error, :still_referenced}
    else
      case Repo.delete(category) do
        {:ok, deleted} -> {:ok, deleted}
        {:error, _changeset} -> {:error, :not_found}
      end
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

  defp conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {"has already been taken", _}} -> true
      _ -> false
    end)
  end
end
