defmodule Dhc.Inventory do
  @moduledoc """
  Inventory capability context.

  ALE-105 implements the **Equipment Category** slice of the Inventory capability
  migration to Phoenix (see `CONTEXT.md` "Svelte service → Phoenix capability
  migration"). Category list/show/create/update/delete behavior flows through
  this module and the `DhcWeb.InventoryCategoriesController` /
  `DhcWeb.InventoryCategoriesJSON` pair; the persistence vocabulary
  (`equipment_categories`, snake_case columns) stays behind this boundary.

  ## Vocabulary

  The persistence table `equipment_categories` is exposed to the public API as
  **Inventory Categories**. JSON payloads use camelCase keys
  (`availableAttributes`, `createdAt`, `updatedAt`, `itemCount`,
  `defaultValue`); the renderer performs the mapping. This module's public
  functions operate on `Dhc.Inventory.EquipmentCategory` structs whose
  `:available_attributes` field is a list of attribute-definition maps (see
  `Dhc.Inventory.JsonArray`).

  ## RBAC

  Authorization is enforced at the **router** layer via pipelines:

    * Reads (`index`, `show`) — any authenticated member
      (`:authenticated_api`).
    * Writes (`create`, `update`, `delete`) — `quartermaster`, `president`, or
      `admin` (the ALE-104 inventory REST contract; mirrored from the existing
      SvelteKit `INVENTORY_ROLES`).

  This module performs no authorization checks itself; it trusts the caller.

  ## Preserved behavior

  The slice preserves the existing SvelteKit `CategoryService` behavior:

    * Categories are listed ordered by `name` ascending, each annotated with an
      `item_count` aggregate.
    * `name` is unique; create/update collisions return `{:error, :conflict}`.
    * Delete is rejected (`{:error, :still_referenced}`) when any
      `inventory_items` row still references the category — callers translate
      this to `409`. The `inventory_items.category_id` FK is `on_delete:
      :nothing`, so the guard is explicit, not DB-enforced.
    * A missing category returns `{:error, :not_found}` (callers translate to
      `404`); it does not raise.

  The `attribute_schema` column is owned by a future item-attribute-validation
  slice and is intentionally untouched here.
  """

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Repo

  @type category :: EquipmentCategory.t()

  @doc """
  Lists equipment categories ordered by `name` ascending, each annotated with
  its `item_count` (the number of `inventory_items` rows referencing it,
  including items under maintenance).

  Returns a list of `EquipmentCategory` structs with `:item_count` populated
  (zero when a category has no items). Never raises.
  """
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

  @doc """
  Fetches a single equipment category by id, annotated with its `item_count`.

  Returns `{:ok, category}` when found, or `{:error, :not_found}` otherwise
  (callers translate to `404`).
  """
  @spec get_category(String.t()) :: {:ok, category()} | {:error, :not_found}
  def get_category(id) when is_binary(id) do
    # `inventory_items` has no Ecto schema in this slice, so the raw-table
    # query doesn't know `category_id` is a uuid. Cast the parameter to
    # `:binary_id` so Postgrex encodes the string UUID as a 16-byte binary.
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

  @doc """
  Creates a new equipment category.

  Accepts a map with string keys (the camelCase request body, e.g.
  `%{"name" => ..., "description" => ..., "availableAttributes" => [...]}`)
  or atom keys. `name` and `availableAttributes` are required by the contract.

  ## Returns

    * `{:ok, category}` — the created category (with `item_count: 0`).
    * `{:error, :conflict, changeset}` — a category with that `name` already
      exists (callers translate to `409`).
    * `{:error, changeset}` — validation failed (callers translate to `422`).
  """
  @spec create_category(map()) ::
          {:ok, category()}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def create_category(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    %EquipmentCategory{}
    |> changeset(normalized)
    |> Repo.insert()
    |> handle_insert_result()
  end

  @doc """
  Updates an existing equipment category.

  Accepts the same writable fields as `create_category/1` (`name`,
  `description`, `availableAttributes`). All three are optional on update:
  only the supplied fields are changed.

  ## Returns

    * `{:ok, category}` — the updated category (with the current `item_count`).
    * `{:error, :not_found}` — no category exists for the given id (`404`).
    * `{:error, :conflict, changeset}` — a category with the new `name` already
      exists (`409`).
    * `{:error, changeset}` — validation failed (`422`).
  """
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
        |> changeset(normalized)
        |> Repo.update()
        |> handle_update_result()
    end
  end

  @doc """
  Deletes an equipment category.

  Rejects the delete (`{:error, :still_referenced}`) when any `inventory_items`
  row still references the category — the `category_id` FK is `on_delete:
  :nothing`, so the guard must be explicit. Callers translate
  `:still_referenced` to `409`.

  ## Returns

    * `{:ok, category}` — the deleted category (its struct, for renderer use).
    * `{:error, :not_found}` — no category exists for the given id (`404`).
    * `{:error, :still_referenced}` — at least one item still references the
      category (`409`).
  """
  @spec delete_category(category() | String.t()) ::
          {:ok, category()} | {:error, :not_found} | {:error, :still_referenced}
  def delete_category(%EquipmentCategory{id: id}), do: delete_category(id)

  def delete_category(id) when is_binary(id) do
    case Repo.get(EquipmentCategory, id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} = category ->
        item_count =
          from(i in "inventory_items",
            where: i.category_id == type(^id, :binary_id),
            select: count(i.id)
          )
          |> Repo.one() || 0

        if item_count > 0 do
          {:error, :still_referenced}
        else
          case Repo.delete(category) do
            {:ok, deleted} -> {:ok, deleted}
            # A unique-via-other constraint won't apply here; surface anything
            # unexpected as a generic failure so callers don't crash.
            {:error, _changeset} -> {:error, :not_found}
          end
        end
    end
  end

  # ── Changeset ───────────────────────────────────────────────────────────

  defp changeset(%EquipmentCategory{} = category, attrs) do
    category
    |> Ecto.Changeset.cast(attrs, [:name, :description, :available_attributes])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 50)
    |> Ecto.Changeset.validate_length(:description, max: 500)
    |> validate_available_attributes()
    |> Ecto.Changeset.unique_constraint(:name, name: :equipment_categories_name_index)
  end

  # The `available_attributes` array may be `nil` (omit on update) or a list of
  # attribute-definition maps. Element shape is validated lightly: each item
  # must be a map and, if it declares a `type`, one of the contract's enum
  # values. We do not reshape element keys here — that's the renderer's job.
  defp validate_available_attributes(changeset) do
    case Ecto.Changeset.get_change(changeset, :available_attributes) do
      nil ->
        changeset

      list when is_list(list) ->
        errors =
          Enum.reduce(list, [], fn item, acc ->
            cond do
              not is_map(item) ->
                [{:available_attributes, "must be an array of attribute definitions"} | acc]

              is_map_key(item, "type") and item["type"] not in ~w(text select number boolean) ->
                [
                  {:available_attributes,
                   "attribute type must be one of: text, select, number, boolean"}
                  | acc
                ]

              true ->
                acc
            end
          end)

        case errors do
          [] -> changeset
          [{field, msg} | _] -> Ecto.Changeset.add_error(changeset, field, msg)
        end

      _ ->
        Ecto.Changeset.add_error(changeset, :available_attributes, "must be an array")
    end
  end

  # ── Request body normalization ──────────────────────────────────────────
  #
  # The OpenAPI contract uses camelCase payload keys (`availableAttributes`).
  # The persistence layer (and `cast/2`) uses snake_case (`available_attributes`).
  # Accept either form so the controller can hand raw params through.

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

  # Looks up the first present key in `attrs`. Accepts the atom, the
  # snake_case string, and (for `available_attributes`) the camelCase contract
  # string, so the controller can hand raw request params (camelCase) and tests
  # can hand snake_case maps through the same path.
  defp map_get(map, keys) do
    Enum.find_value(keys, fn
      key when is_atom(key) -> Map.get(map, key)
      key when is_binary(key) -> Map.get(map, key)
    end)
  end

  # ── Result handling ────────────────────────────────────────────────────

  defp handle_insert_result({:ok, %EquipmentCategory{} = category}) do
    {:ok, %EquipmentCategory{category | item_count: 0}}
  end

  defp handle_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if conflict?(changeset), do: {:error, :conflict, changeset}, else: {:error, changeset}
  end

  defp handle_update_result({:ok, %EquipmentCategory{} = category}) do
    # Re-annotate item_count so the rendered payload matches the post-update
    # state (number of referencing items is unaffected by a category edit, but
    # fetching it keeps the rendered shape uniform with create/show/list).
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

  # The unique constraint is the only constraint that should surface as a
  # `409`; everything else (required field, length, attribute shape) is a `422`.
  defp conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {"has already been taken", _}} -> true
      _ -> false
    end)
  end
end
