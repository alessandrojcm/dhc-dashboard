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

  alias Dhc.Inventory.Container
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.InventoryHistory
  alias Dhc.Inventory.Item
  alias Dhc.Repo

  @type category :: EquipmentCategory.t()
  @type container :: Container.t()
  @type item :: Item.t()
  @type history :: InventoryHistory.t()

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

  # ═══════════════════════════════════════════════════════════════════════
  # Containers — ALE-106
  # ═══════════════════════════════════════════════════════════════════════
  #
  # Implements the **Container** slice of the Inventory capability migration.
  #  The persistence table is `containers` (`parent_container_id` self-FK,
  # NOT-NULL `created_by` FK → `auth.users`); the public API contract (see
  # `apps/phoenix/priv/api/openapi.yaml`) exposes these as **Inventory
  # Containers** with camelCase payload keys (`parentContainerId`,
  # `parentContainer`, `childContainers`, `itemCount`, `createdAt`). The
  # `DhcWeb.InventoryContainersController` / `DhcWeb.InventoryContainersJSON`
  # pair renders that mapping.
  #
  # ## RBAC
  #
  # As with categories, authorization is enforced at the router layer:
  #
  #   * Reads (`index`, `show`) — any authenticated member (`:authenticated_api`).
  #   * Writes (`create`, `update`, `delete`) — `quartermaster`, `president`,
  #     or `admin` (the ALE-104 inventory REST contract; mirrors the existing
  #     SvelteKit `INVENTORY_ROLES`).
  #
  # This module trusts the caller.
  #
  # ## Preserved behavior
  #
  # Mirrors the existing SvelteKit `ContainerService`:
  #
  #   * `list_containers/0` returns a flat list ordered by `name`, each with an
  #     `item_count` (direct items only) and a `parent_container` `{id, name}`
  #     summary; the UI rebuilds the hierarchy client-side from
  #     `parent_container_id`.
  #   * `get_container/1` returns a detail with `parent_container`,
  #     `child_containers`, and the direct `items` (each carrying a `category`
  #     summary). Item-level history is not embedded (it belongs to the item slice).
  #   * `create_container/2` derives `created_by` from the caller's JWT `sub`
  #     (never user-writable).
  #   * `update_container/2` accepts `name`, `description`, and
  #     `parent_container_id` (camelCase `parentContainerId` accepted).
  #     Circular-parent prevention is enforced server-side: setting the parent
  #     to the container itself or any of its descendants returns
  #     `{:error, :circular_parent}` so the UI and any non-UI client cannot
  #     create a cycle that would infinite-loop the client hierarchy builder.
  #   * `delete_container/1` is rejected with `{:error, :still_referenced}` when
  #     the container directly contains items. Child containers cascade-delete
  #     (`containers.parent_container_id` is `on_delete: :delete_all`); a
  #     child that itself holds items blocks the cascade — surfaced as
  #     `:still_referenced` (409) too.
  #   * A missing container returns `{:error, :not_found}` (callers translate
  #     to `404`); it does not raise.

  @doc """
  Lists inventory containers as a flat list ordered by `name`, each annotated
  with its `item_count` (number of `inventory_items` rows directly in it) and
  a `parent_container` summary (`%{"id" => ..., "name" => ...}` or `nil`).

  The UI rebuilds the parent/child hierarchy client-side from
  `parent_container_id` + the `parent_container` summary; this endpoint does
  not return a nested tree. Never raises.
  """
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

  @doc """
  Fetches a single inventory container by id with its relations: a
  `parent_container` summary, the `child_containers` (`[%{"id", "name"}]`),
  the direct `items` (each carrying a `category` summary), and `item_count`.

  ## Returns

    * `{:ok, container}` — the container with virtual relations populated.
    * `{:error, :not_found}` — callers translate to `404`.
  """
  @spec get_container(String.t()) :: {:ok, container()} | {:error, :not_found}
  def get_container(id) when is_binary(id) do
    case Repo.get(Container, id) do
      nil -> {:error, :not_found}
      %Container{} = container -> {:ok, load_container_relations(container)}
    end
  end

  @doc """
  Creates a new inventory container.

  Accepts a map with string or atom keys (the camelCase request body, e.g.
  `%{"name" => ..., "description" => ..., "parentContainerId" => ...}`).
  `name` is required by the contract. `created_by` is set programmatically
  from `actor_id` (the caller's Supabase JWT `sub`); it is never taken from
  the request body.

  ## Returns

    * `{:ok, container}` — the created container (with `item_count: 0` and a
      populated `parent_container` summary).
    * `{:error, changeset}` — validation failed (callers translate to `422`).
      Foreign-key failures (`parentContainerId` refers to a missing container,
      or the actor user does not exist) surface as changeset errors via
      `foreign_key_constraint/3` rather than raising.
  """
  @spec create_container(map(), String.t()) ::
          {:ok, container()} | {:error, Ecto.Changeset.t()}
  def create_container(attrs, actor_id) when is_map(attrs) and is_binary(actor_id) do
    normalized = normalize_container_attrs(attrs)

    %Container{created_by: actor_id}
    |> container_changeset(normalized)
    |> Repo.insert()
    |> handle_container_insert()
  end

  @doc """
  Updates an existing inventory container.

  Accepts the same writable fields as `create_container/2` (`name`,
  `description`, `parent_container_id` / `parentContainerId`). All fields are
  optional on update: only keys present in the payload are changed. To detach a
  container to the root level, send `parentContainerId: null` (or `""`).

  Setting `parentContainerId` to the container itself or any of its descendants
  returns `{:error, :circular_parent}` (preserves the Svelte UI's
  descendant-filtering as a server-side invariant).

  ## Returns

    * `{:ok, container}` — the updated container (with the current `item_count`
      and refreshed `parent_container` summary).
    * `{:error, :not_found}` — no container exists for the given id (`404`).
    * `{:error, :circular_parent}` — `parentContainerId` is the container or a
      descendant (callers translate to `422`).
    * `{:error, changeset}` — validation failed (`422`), e.g. a missing parent.
  """
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

  @doc """
  Deletes an inventory container.

  Rejects the delete (`{:error, :still_referenced}`) when the container still
  directly contains inventory items — the `inventory_items.container_id` FK is
  `on_delete: :nothing`, so the guard must be explicit. Child containers
  cascade-delete (`containers.parent_container_id` is `on_delete: :delete_all`);
  a child that itself holds items blocks the cascade, also surfaced as
  `:still_referenced` (409). Callers translate `:still_referenced` to `409`.

  ## Returns

    * `{:ok, container}` — the deleted container (for renderer use).
    * `{:error, :not_found}` — no container exists for the given id (`404`).
    * `{:error, :still_referenced}` — the container (or a cascaded child) still
      contains items (`409`).
  """
  @spec delete_container(String.t()) ::
          {:ok, container()} | {:error, :not_found} | {:error, :still_referenced}
  def delete_container(id) when is_binary(id) do
    case Repo.get(Container, id) do
      nil ->
        {:error, :not_found}

      %Container{} = container ->
        if direct_item_count(id) > 0 do
          {:error, :still_referenced}
        else
          case Repo.delete(container) do
            {:ok, deleted} -> {:ok, deleted}
            # Either an unexpected error or a cascaded child blocked by its own
            # items (the `inventory_items.container_id` FK is
            # `on_delete: :nothing`). Both mean "still contains items" → 409.
            {:error, _changeset} -> {:error, :still_referenced}
          end
        end
    end
  end

  # ── Container relations (detail) ───────────────────────────────────────

  defp load_container_relations(%Container{} = container) do
    # `items` is fetched here (the detail page renders them) and its length is
    # the canonical `item_count`; no separate count query is needed.
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

  # `inventory_items` and `equipment_categories` are raw tables here (the items
  # slice will introduce an `inventory_items` schema). Cast the parent id to
  # `:binary_id` so Postgrex encodes the string UUID as a 16-byte binary for
  # the raw-table `container_id` uuid column. The `category` summary is built
  # server-side via `json_build_object` so item rows with no category surface
  # as `nil` rather than being filtered out by an inner join.
  #
  # Raw-table selects carry no Ecto type, so `i.id` (a uuid column) comes back
  # from Postgrex as the raw 16-byte binary, which Jason cannot encode. Cast it
  # (and the category id inside the jsonb) to `::text` so the wire shape carries
  # canonical string UUIDs. `container_id`/`category_id` filter params still go
  # in as binaries via `type(^.., :binary_id)`.
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

  # ── Container changeset ────────────────────────────────────────────────

  defp container_changeset(%Container{} = container, attrs) do
    container
    |> Ecto.Changeset.cast(attrs, [:name, :description, :parent_container_id])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 100)
    |> Ecto.Changeset.validate_length(:description, max: 500)
    # `created_by` is set on the struct, never cast; guard it nonetheless so a
    # missing auth.users row surfaces as a changeset error (422) rather than a
    # DB raise. The parent FK guard turns a missing `parentContainerId` into
    # a changeset error too.
    |> Ecto.Changeset.foreign_key_constraint(:parent_container_id,
      name: :containers_parent_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:created_by, name: :containers_created_by_fkey)
  end

  # ── Container request body normalization ────────────────────────────────
  #
  # The OpenAPI contract uses camelCase payload keys (`parentContainerId`); the
  # persistence layer (and `cast/2`) uses snake_case (`parent_container_id`).
  # Accept either form so the controller can hand raw params through. Only
  # keys present in the request are included in the normalized map: a missing
  # `parent_container_id` leaves the parent unchanged on update (PATCH
  # semantics), while an explicit `null`/`""` detaches the container to the
  # root level.

  defp normalize_container_attrs(attrs) when is_map(attrs) do
    normalized =
      [
        # {destination, [source aliases in lookup order]}
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
      :absent ->
        normalized

      value ->
        Map.put(normalized, "parent_container_id", normalize_parent_id(value))
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

  # Empty strings and explicit nulls normalize to nil == root container.
  defp normalize_parent_id(nil), do: nil
  defp normalize_parent_id(""), do: nil
  defp normalize_parent_id(value) when is_binary(value), do: value
  defp normalize_parent_id(value), do: value

  # ── Container cycle detection ──────────────────────────────────────────
  #
  # Setting `parent_container_id` to the container itself or any of its
  # descendants would create a cycle. The client hierarchy builder
  # (`buildHierarchy`) recurses without memoization, so a cycle in the DB would
  # infinite-loop the list page — therefore the server enforces the invariant
  # even though the Svelte UI also filters available parents client-side.
  #
  # We detect the cycle by walking the current `parent_container_id` chain up
  # from the proposed new parent: if it reaches `container_id`, the proposed
  # parent is a descendant of `container_id` (or is `container_id` itself).

  defp circular_parent?(container_id, normalized) do
    case Map.get(normalized, "parent_container_id") do
      # No parent change in this request, or detaching to root → no cycle.
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

  # All container ids → their current parent id, as a plain map. Walking up the
  # parent chain from a single container would touch O(depth) rows, but
  # loading the whole map keeps the walk in-memory and bounded by the
  # (small) inventory container count.
  defp container_parent_map do
    from(c in Container, select: {c.id, c.parent_container_id})
    |> Repo.all()
    |> Map.new()
  end

  # ── Container result handling ──────────────────────────────────────────

  defp handle_container_insert({:ok, %Container{} = container}) do
    {:ok, populate_flat_aggregates(container)}
  end

  defp handle_container_insert({:error, %Ecto.Changeset{} = changeset}) do
    {:error, changeset}
  end

  defp handle_container_update({:ok, %Container{} = container}, id) do
    # Re-read so the virtual aggregates (`item_count`, `parent_container`)
    # reflect post-update state; they are not persisted columns.
    case Repo.get(Container, id) do
      nil -> {:ok, populate_flat_aggregates(container)}
      %Container{} = fresh -> {:ok, populate_flat_aggregates(fresh)}
    end
  end

  defp handle_container_update({:error, %Ecto.Changeset{} = changeset}, _id) do
    {:error, changeset}
  end

  # Populates the flat (list/create/update response) virtual aggregates:
  # `item_count` and `parent_container` summary. `child_containers` and
  # `items` are left at their schema defaults (`[]`) — they only belong to the
  # detail (`get_container/1`) shape.
  defp populate_flat_aggregates(%Container{} = container) do
    %Container{
      container
      | item_count: direct_item_count(container.id),
        parent_container: parent_summary(container.parent_container_id)
    }
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Items — ALE-107
  # ═══════════════════════════════════════════════════════════════════════
  #
  # Implements the **Item** slice of the Inventory capability migration.
  # The persistence table is `inventory_items` (NOT NULL `container_id` and
  # `category_id` FKs, nullable `created_by`/`updated_by` FKs → `auth.users`,
  # positive-quantity CHECK, free-form jsonb `attributes`); the public API
  # contract (see `apps/phoenix/priv/api/openapi.yaml`) exposes these as
  # **Inventory Items** with camelCase payload keys (`containerId`,
  # `categoryId`, `outForMaintenance`, `photoUrl`, `createdAt`, `updatedAt`,
  # `createdBy`, `updatedBy`) plus `container`/`category` summaries. The
  # `DhcWeb.InventoryItemsController` / `DhcWeb.InventoryItemsJSON` pair
  # renders that mapping.
  #
  # ## RBAC
  #
  # As with categories and containers, authorization is enforced at the router
  # layer:
  #
  #   * Reads (`index`, `show`, `history`) — any authenticated member
  #     (`:authenticated_api`).
  #   * Writes (`create`, `update`, `delete`) — `quartermaster`, `president`,
  #     or `admin` (the ALE-104 inventory REST contract; mirrors the existing
  #     SvelteKit `INVENTORY_ROLES`).
  #
  # This module trusts the caller.
  #
  # ## History recording
  #
  # Per the ALE-107 design decision: the slice records a `created`
  # `inventory_history` row on insert and an `updated` row on patch (each
  # inside the same transaction as the item write, with `changed_by` = the
  # caller's JWT `sub`). When `update_item/3` changes `container_id`, a
  # `moved` row is recorded first — preserving the SvelteKit
  # `ItemService.moveToContainer` history behavior inside the unified update
  # path. On delete, no dedicated history row is written: the
  # `inventory_history.item_id` FK is `on_delete: :delete_all`, so a "deleted"
  # row would be cascade-wiped alongside the item and is pointless; the
  # item's prior history rows are removed by the same cascade.
  #
  # ## Preserved behavior
  #
  # Mirrors the existing SvelteKit `ItemService`:
  #
  #   * `list_items/1` returns items newest-first (by `created_at` desc, `id`
  #     desc tiebreaker), each carrying a `container` (`{id, name,
  #     parent_container_id}`) and `category` (`{id, name}`) summary. Filters:
  #     `categoryId`, `containerId`, `outForMaintenance`, `search`
  #     (case-insensitive partial match across notes, category name, and
  #     container name). Cursor pagination over `(created_at, id)`.
  #   * `get_item/1` returns the item with the same `container`/`category`
  #     summaries.
  #   * `create_item/2` derives `created_by` from the caller's JWT `sub`
  #     (never user-writable).
  #   * `update_item/3` accepts the same writable fields as create, all
  #     optional on update (PATCH semantics). `updated_by` is set from the
  #     caller's JWT `sub`.
  #   * `delete_item/1` hard-deletes the item (cascading history).
  #   * `list_item_history/2` returns the most recent `inventory_history`
  #     rows for one item, newest first, with `old_container`/`new_container`
  #     name summaries.
  #   * A missing item returns `{:error, :not_found}` (callers translate to
  #     `404`); it does not raise.
  #   * Unknown `container_id` / `category_id` on create or update surface as
  #     changeset errors via `foreign_key_constraint/3` (callers translate to
  #     `422`).

  @item_allowed_limits [10, 25, 50, 100]
  @item_default_limit 50

  @doc """
  Lists inventory items, newest first, with `container` and `category`
  summaries. Cursor-paginated over `(created_at, id)` (newest first).

  ## Options

    * `:limit` — one of `10, 25, 50, 100` (defaults to `50`).
    * `:cursor` — opaque cursor returned by a previous response, or `nil`.
    * `:category_id` — filter by category id (binary UUID).
    * `:container_id` — filter by container id (binary UUID).
    * `:out_for_maintenance` — `true`/`false` filter on the maintenance flag.
    * `:search` — case-insensitive partial match across item notes, category
      name, and container name.

  ## Returns

    * `{:ok, %{items: [...], limit: pos_integer, next_cursor: binary | nil}}`
      — the page plus the cursor for the next page (`nil` when this is the
      last page).
    * `{:error, :invalid_limit}` — `:limit` is outside `@item_allowed_limits`.
    * `{:error, :bad_cursor}` — `:cursor` is malformed or stale (filters
      changed since it was issued).
  """
  @spec list_items(keyword() | map()) ::
          {:ok, %{items: [item()], limit: pos_integer, next_cursor: binary | nil}}
          | {:error, :invalid_limit | :bad_cursor}
  def list_items(opts \\ %{}) when is_map(opts) or is_list(opts) do
    opts = normalize_list_opts(opts)

    with :ok <- validate_limit(opts.limit),
         {:ok, cursor} <- parse_item_cursor(opts.cursor, opts) do
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
         next_cursor: next_item_cursor(visible, rows, opts)
       }}
    end
  end

  @doc """
  Fetches a single inventory item by id with `container` and `category`
  summaries.

  ## Returns

    * `{:ok, item}` — the item with virtual aggregates populated.
    * `{:error, :not_found}` — callers translate to `404`.
  """
  @spec get_item(String.t()) :: {:ok, item()} | {:error, :not_found}
  def get_item(id) when is_binary(id) do
    case Repo.get(Item, id) do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, load_item_aggregates(item)}
    end
  end

  @doc """
  Creates a new inventory item and records a `created` `inventory_history`
  row in the same transaction.

  Accepts a map with string or atom keys (the camelCase request body, e.g.
  `%{"containerId" => ..., "categoryId" => ..., "quantity" => ...}`).
  `containerId` and `categoryId` are required; `quantity` is required and
  must be positive (DB CHECK). `created_by` is set programmatically from
  `actor_id` (the caller's Supabase JWT `sub`); it is never taken from the
  request body.

  ## Returns

    * `{:ok, item}` — the created item with `container`/`category` populated.
    * `{:error, changeset}` — validation failed (callers translate to `422`).
      Foreign-key failures (`containerId`/`categoryId` refers to a missing
      row, or the actor user does not exist) surface as changeset errors via
      `foreign_key_constraint/3` rather than raising.
  """
  @spec create_item(map(), String.t()) ::
          {:ok, item()} | {:error, Ecto.Changeset.t()}
  def create_item(attrs, actor_id) when is_map(attrs) and is_binary(actor_id) do
    normalized = normalize_item_attrs(attrs)

    item_changeset =
      %Item{created_by: actor_id}
      |> item_changeset(normalized)
      # Ensure the changeset carries the FK guards so DB-level failures
      # surface as changeset errors (422) rather than raising.
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
      record_created_history(item, actor_id, Map.get(normalized, "notes"))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{item: %Item{} = item}} ->
        {:ok, load_item_aggregates(item)}

      {:error, :item, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, :history, _changeset, _changes} ->
        # The history insert failed after the item inserted; the whole
        # transaction rolled back, so there is no orphan item. Surface a
        # generic changeset so the caller maps to 422.
        {:error, %Ecto.Changeset{errors: [history: {"could not record history", []}]}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Updates an existing inventory item and records history side-effects in the
  same transaction.

  Accepts the same writable fields as `create_item/2` (`containerId`,
  `categoryId`, `quantity`, `attributes`, `notes`, `outForMaintenance`,
  `photoUrl`), all optional on update (PATCH semantics). `updated_by` is set
  from the caller's JWT `sub`.

  When `containerId` changes, a `moved` `inventory_history` row is recorded
  first (with the old/new container ids), then an `updated` row is recorded
  — preserving the SvelteKit `ItemService.moveToContainer` history behavior
  inside the unified update path.

  ## Returns

    * `{:ok, item}` — the updated item with `container`/`category` populated.
    * `{:error, :not_found}` — no item exists for the given id (`404`).
    * `{:error, changeset}` — validation failed (`422`), e.g. a missing
      container or category.
  """
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

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.update(:item, changeset)

        multi =
          if container_changed?(old_container_id, new_container_id) do
            Ecto.Multi.insert(
              multi,
              :history_moved,
              record_moved_history(
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
            record_updated_history(item.id, actor_id, Map.get(normalized, "notes"))
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

  @doc """
  Deletes an inventory item. `inventory_history.item_id` is `on_delete:
  :delete_all`, so the item's history rows are cascade-removed with it; no
  dedicated `deleted` history row is recorded (it would be cascade-wiped and
  is pointless).

  ## Returns

    * `{:ok, item}` — the deleted item (for renderer use).
    * `{:error, :not_found}` — no item exists for the given id (`404`).
  """
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
  Lists the most recent `inventory_history` rows for one item, newest first,
  with `old_container`/`new_container` name summaries.

  Returns `{:error, :not_found}` when the item id does not exist (callers
  translate to `404`). `limit` is clamped to `1..100` and defaults to `20`.
  """
  @spec list_item_history(String.t(), keyword() | map()) ::
          {:ok, [history()]} | {:error, :not_found}
  def list_item_history(id, opts \\ %{}) when is_binary(id) do
    case Repo.get(Item, id) do
      nil ->
        {:error, :not_found}

      %Item{} ->
        limit = history_limit(opts)

        rows =
          from(h in InventoryHistory,
            left_join: old in Container,
            on: old.id == h.old_container_id,
            left_join: new in Container,
            on: new.id == h.new_container_id,
            where: h.item_id == ^id,
            order_by: [desc: h.created_at, desc: h.id],
            limit: ^limit,
            select_merge: %{
              old_container:
                fragment(
                  "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
                  old.id,
                  old.id,
                  old.name
                ),
              new_container:
                fragment(
                  "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?::text, 'name', ?) ELSE NULL END",
                  new.id,
                  new.id,
                  new.name
                )
            }
          )
          |> Repo.all()

        {:ok, rows}
    end
  end

  # ── Item list query ──────────────────────────────────────────────────────

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

  # Apply the cursor to the base query. The cursor carries the last
  # `(created_at, id)` of the previous page; this page starts strictly after
  # it (newest first).
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, %{created_at: created_at, id: id}) do
    where(
      query,
      [i],
      i.created_at < ^created_at or (i.created_at == ^created_at and i.id < ^id)
    )
  end

  # ── Item list option normalization ───────────────────────────────────────

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

  # ── Item cursor encoding ──────────────────────────────────────────────────
  #
  # The cursor is an opaque, URL-safe-base64 JSON object carrying the last
  # `(created_at, id)` of the previous page plus the filter signature (so a
  # stale cursor from a different filter set is rejected as `:bad_cursor`
  # rather than silently serving the wrong page).

  defp parse_item_cursor(nil, _opts), do: {:ok, nil}

  defp parse_item_cursor(cursor, opts) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json),
         %{"createdAt" => created_at, "id" => id, "filters" => filters} <- decoded,
         true <- filters == item_cursor_filters(opts) do
      with {:ok, dt, _} <- DateTime.from_iso8601(created_at) do
        {:ok, %{created_at: dt, id: id}}
      else
        _ -> {:error, :bad_cursor}
      end
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp next_item_cursor(visible, rows, opts) do
    # If we did not fetch the lookahead row, this is the last page → no cursor.
    if length(rows) <= opts.limit do
      nil
    else
      %Item{} = last = List.last(visible)
      encode_item_cursor(last, opts)
    end
  end

  defp encode_item_cursor(%Item{} = item, opts) do
    Jason.encode!(%{
      "createdAt" => serialize_dt(item.created_at),
      "id" => item.id,
      "filters" => item_cursor_filters(opts)
    })
    |> Base.url_encode64(padding: false)
  end

  defp item_cursor_filters(opts) do
    %{
      "limit" => opts.limit,
      "categoryId" => opts.category_id,
      "containerId" => opts.container_id,
      "outForMaintenance" => opts.out_for_maintenance,
      "search" => opts.search
    }
  end

  defp history_limit(opts) when is_map(opts) do
    opts
    |> Map.get("limit")
    |> parse_integer(20)
    |> max(1)
    |> min(100)
  end

  defp history_limit(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> history_limit()
  end

  # ── Item aggregates ──────────────────────────────────────────────────────

  defp load_item_aggregates(%Item{} = item) do
    %Item{
      item
      | container: container_summary(item.container_id),
        category: category_summary(item.category_id)
    }
  end

  # `{id, name, parent_container_id}` — matches the `InventoryItem.container`
  # contract shape. `parent_container_id` lets the UI render the parent
  # without a second round-trip.
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

  # ── Item changeset ───────────────────────────────────────────────────────

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

  # ── Item request body normalization ──────────────────────────────────────
  #
  # The OpenAPI contract uses camelCase payload keys (`containerId`,
  # `categoryId`, `outForMaintenance`, `photoUrl`); the persistence layer (and
  # `cast/2`) uses snake_case (`container_id`, `category_id`,
  # `out_for_maintenance`, `photo_url`). Accept either form so the controller
  # can hand raw params through. Only keys present in the request are included
  # in the normalized map: a missing key leaves the field unchanged on update
  # (PATCH semantics).

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

  # ── History recording helpers ────────────────────────────────────────────

  defp record_created_history(%Item{} = item, actor_id, notes) do
    %InventoryHistory{
      item_id: item.id,
      action: :created,
      old_container_id: nil,
      new_container_id: item.container_id,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  defp record_moved_history(item_id, old_container_id, new_container_id, actor_id, notes) do
    %InventoryHistory{
      item_id: item_id,
      action: :moved,
      old_container_id: old_container_id,
      new_container_id: new_container_id,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:old_container_id,
      name: :inventory_history_old_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:new_container_id,
      name: :inventory_history_new_container_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  defp record_updated_history(item_id, actor_id, notes) do
    %InventoryHistory{
      item_id: item_id,
      action: :updated,
      old_container_id: nil,
      new_container_id: nil,
      changed_by: actor_id,
      notes: notes,
      created_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:item_id, name: :inventory_history_item_id_fkey)
    |> Ecto.Changeset.foreign_key_constraint(:changed_by,
      name: :inventory_history_changed_by_fkey
    )
  end

  defp container_changed?(nil, nil), do: false
  defp container_changed?(a, b) when a == b, do: false
  defp container_changed?(_old, _new), do: true

  defp serialize_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
