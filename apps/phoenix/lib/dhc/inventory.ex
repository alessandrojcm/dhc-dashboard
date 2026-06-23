defmodule Dhc.Inventory do
  @moduledoc """
  Inventory read-model helpers used by Phoenix API controllers.

  This is the first Inventory read slice (issue ALE-94 / PRD #93): the
  overview counts endpoint. It establishes the minimal Ecto schema/query
  helper coverage needed for the overview path so later endpoint slices
  (activity, categories, containers, items — see PRD #93) can build on
  these schemas without re-deriving them.

  ## Vocabulary

  `inventory_items`, `equipment_categories`, `containers`, and
  `inventory_history` are **persistence** names only. The schemas in
  `Dhc.Inventory.*` map those tables, but every value returned from this
  module uses Inventory language: Container, Equipment Category, Inventory
  Item, and Inventory Activity. Controllers must not return the raw schemas;
  they return the maps built here.

  ## Authorization (RBAC) — read before reusing

  RBAC is enforced at the **controller** layer (mirroring the Waitlist,
  Members, and Workshops read migrations), not inside these helpers. The
  intended Phoenix RBAC for Inventory management reads mirrors the current
  dashboard Inventory gate:

      @inventory_management_roles ~w(quartermaster president admin)

  A member without an Inventory privilege must not read Inventory
  management data. This is stricter than the Workshops member collection
  (`authenticated_api`): the Inventory overview is a management-only read.

  ## Scope of this slice

  This module covers the overview counts (`GET /api/inventory/overview`,
  ALE-94), the Inventory Activity feed (`GET /api/inventory/activity`,
  ALE-95), the Inventory Item filter options
  (`GET /api/inventory/items/filters`, ALE-98), the Equipment Category list
  (`GET /api/inventory/categories`, ALE-96), and the Container list
  (`GET /api/inventory/containers`, ALE-97). Later endpoint slices
  (items — see PRD #93) can build on these schemas without re-deriving them.
  """

  import Ecto.Query

  alias Dhc.Inventory.{Container, EquipmentCategory, InventoryActivity, InventoryItem}
  alias Dhc.Repo

  # The canonical Phoenix RBAC for Inventory management reads. Mirrors the
  # current dashboard Inventory gate (`INVENTORY_ROLES` in
  # `src/lib/server/roles.ts`). Future controllers should reference this
  # list as the source of truth.
  @inventory_management_roles ~w(quartermaster president admin)

  @doc """
  Returns the canonical Inventory management roles.

  Exposed so the controller authorization plug and tests build against the
  same source of truth as this context, and so tests can assert the gate
  has not drifted.
  """
  @spec inventory_management_roles() :: [String.t()]
  def inventory_management_roles, do: @inventory_management_roles

  @doc """
  Returns the Inventory overview summary counts.

  The summary is a domain-shaped map with snake_case keys; the controller
  JSON renderer converts them to the camelCase contract
  (`summary.containerCount`, `summary.categoryCount`, `summary.itemCount`,
  `summary.maintenanceCount`).

  `maintenanceCount` is the number of Inventory Items currently out for
  maintenance (`out_for_maintenance = true`). It is a subset of
  `itemCount`, mirroring the existing SvelteKit read
  (`src/routes/dashboard/inventory/+page.server.ts`).

  Each count is a separate `SELECT count(*)` query rather than a single
  join/aggregation: the four counts are over different tables with no
  shared join key, and `maintenanceCount` is a filtered subset of
  `itemCount`. Running them in parallel via `Task.async_stream/3` keeps the
  overview endpoint fast without complicating the query layer.
  """
  @spec overview_counts() :: %{
          container_count: non_neg_integer(),
          category_count: non_neg_integer(),
          item_count: non_neg_integer(),
          maintenance_count: non_neg_integer()
        }
  def overview_counts do
    [
      fn -> Repo.one(from c in Container, select: count(c.id)) end,
      fn -> Repo.one(from c in EquipmentCategory, select: count(c.id)) end,
      fn -> Repo.one(from i in InventoryItem, select: count(i.id)) end,
      fn ->
        Repo.one(
          from i in InventoryItem,
            where: i.out_for_maintenance == true,
            select: count(i.id)
        )
      end
    ]
    |> Task.async_stream(
      fn fun -> fun.() end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, value} -> value end)
    |> then(fn [containers, categories, items, maintenance] ->
      %{
        container_count: containers || 0,
        category_count: categories || 0,
        item_count: items || 0,
        maintenance_count: maintenance || 0
      }
    end)
  end

  # ── Inventory Activity feed (ALE-95) ─────────────────────────────────
  #
  # Cursor-paginated, newest-first (`created_at desc, id desc`), with no total
  # count. Mirrors the Notifications cursor pattern: forward-only pagination
  # via an opaque base64url-encoded JSON cursor binding `{limit, id, createdAt,
  # itemId, containerId}`; the response carries `nextCursor` (or `nil`).
  #
  # `limit + 1` is fetched so a non-nil `nextCursor` signals another page
  # without a separate `COUNT(*)`. The DTO joins `inventory_items` (for the
  # nested `item` object) and `containers` twice (old/new) for the nested
  # container objects, matching the legacy SvelteKit Kysely read shape in
  # `src/routes/dashboard/inventory/+page.server.ts`.

  @allowed_limits [10, 25, 50, 100]

  @doc """
  Returns cursor-paginated, domain-shaped Inventory Activity entries.

  Newest-first, ordered by `created_at desc, id desc` (deterministic
  tie-break). No total count is returned: the overview counts already provide
  the summary totals, and the activity feed is an open-ended log, not a
  paginated table.

  ## Options

    * `"limit"` (default `10`) — one of `10`, `25`, `50`, `100`.
    * `"cursor"` — opaque cursor from a previous response.
    * `"itemId"` — constrain the feed to a single Inventory Item.
    * `"containerId"` — constrain the feed to activities whose
      `oldContainerId` or `newContainerId` equals the given Container id.

  ## Returns

    * `{:ok, %{activity: [map], limit: integer, next_cursor: binary | nil}}`
    * `{:error, :invalid_limit}` / `{:error, :bad_item_id}` /
      `{:error, :bad_container_id}` / `{:error, :bad_cursor}`
  """
  @spec list_activity(map()) ::
          {:ok, %{activity: [map()], limit: integer, next_cursor: binary | nil}}
          | {:error, :invalid_limit | :bad_item_id | :bad_container_id | :bad_cursor}
  def list_activity(params \\ %{}) do
    with {:ok, opts} <- parse_activity_options(params),
         {:ok, cursor} <- parse_activity_cursor(opts) do
      rows = activity_rows(opts, cursor)
      visible_rows = Enum.take(rows, opts.limit)

      {:ok,
       %{
         activity: visible_rows,
         limit: opts.limit,
         next_cursor: next_activity_cursor(visible_rows, rows, opts)
       }}
    end
  end

  defp parse_activity_options(params) do
    limit = parse_integer(Map.get(params, "limit", "10"))
    item_id = blank_to_nil(Map.get(params, "itemId"))
    container_id = blank_to_nil(Map.get(params, "containerId"))

    cond do
      limit not in @allowed_limits ->
        {:error, :invalid_limit}

      item_id != nil and not valid_uuid?(item_id) ->
        {:error, :bad_item_id}

      container_id != nil and not valid_uuid?(container_id) ->
        {:error, :bad_container_id}

      true ->
        {:ok,
         %{
           limit: limit,
           item_id: item_id,
           container_id: container_id,
           cursor: blank_to_nil(Map.get(params, "cursor"))
         }}
    end
  end

  defp valid_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_activity_cursor(%{cursor: nil}), do: {:ok, nil}

  defp parse_activity_cursor(opts) do
    with {:ok, json} <- Base.url_decode64(opts.cursor, padding: false),
         {:ok, cursor} <- Jason.decode(json),
         true <- cursor["limit"] == opts.limit,
         true <- cursor["itemId"] == opts.item_id,
         true <- cursor["containerId"] == opts.container_id,
         {:ok, _id} <- Ecto.UUID.cast(cursor["id"]),
         {:ok, _created_at, _offset} <- DateTime.from_iso8601(cursor["createdAt"]) do
      {:ok, cursor}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp activity_rows(opts, cursor) do
    base =
      from h in InventoryActivity,
        left_join: item in InventoryItem,
        on: item.id == h.item_id,
        left_join: old_c in Container,
        on: old_c.id == h.old_container_id,
        left_join: new_c in Container,
        on: new_c.id == h.new_container_id,
        select: %{
          id: h.id,
          action: h.action,
          changed_by: h.changed_by,
          created_at: h.created_at,
          item_id: h.item_id,
          old_container_id: h.old_container_id,
          new_container_id: h.new_container_id,
          notes: h.notes,
          item:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?, 'attributes', ?) ELSE NULL END",
              item.id,
              item.id,
              item.attributes
            ),
          old_container:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?, 'name', ?) ELSE NULL END",
              old_c.id,
              old_c.id,
              old_c.name
            ),
          new_container:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN json_build_object('id', ?, 'name', ?) ELSE NULL END",
              new_c.id,
              new_c.id,
              new_c.name
            )
        }

    base
    |> filter_item_id(opts.item_id)
    |> filter_container_id(opts.container_id)
    |> apply_activity_cursor(cursor)
    |> order_by([h], desc: h.created_at, desc: h.id)
    |> limit(^opts.limit + 1)
    |> Repo.all()
  end

  defp filter_item_id(query, nil), do: query

  defp filter_item_id(query, item_id),
    do: where(query, [h], h.item_id == ^item_id)

  defp filter_container_id(query, nil), do: query

  defp filter_container_id(query, container_id),
    do:
      where(
        query,
        [h],
        h.old_container_id == ^container_id or h.new_container_id == ^container_id
      )

  defp apply_activity_cursor(query, nil), do: query

  defp apply_activity_cursor(query, cursor) do
    where(
      query,
      [h],
      h.created_at < type(^cursor["createdAt"], :utc_datetime) or
        (h.created_at == type(^cursor["createdAt"], :utc_datetime) and h.id < ^cursor["id"])
    )
  end

  defp next_activity_cursor([], _rows, _opts), do: nil

  defp next_activity_cursor(visible_rows, rows, opts) do
    if length(rows) > opts.limit,
      do: visible_rows |> List.last() |> encode_activity_cursor(opts)
  end

  defp encode_activity_cursor(nil, _opts), do: nil

  defp encode_activity_cursor(row, opts) do
    %{
      limit: opts.limit,
      itemId: opts.item_id,
      containerId: opts.container_id,
      id: row.id,
      createdAt: DateTime.to_iso8601(row.created_at)
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # ── Inventory Item filter options (ALE-98) ───────────────────────────
  #
  # Returns the Equipment Category and Container options used to populate the
  # Inventory Item list filter dropdowns. Replaces the SvelteKit server-side
  # `getFilterOptions()` read (`item.service.ts`), which ran `selectAll()` over
  # `equipment_categories` and `containers` ordered by `name`.
  #
  # The DTO is intentionally minimal: dropdowns only need `id` + `name`, plus
  # the category attribute definitions (`availableAttributes`/`attributeSchema`)
  # for any future attribute-driven filter UI, and `parentContainerId` for
  # hierarchical container display. Internal timestamps and auth-user refs
  # (`created_by`) are not exposed — the `inserted_at`/`created_at` baseline
  # divergence (see AGENTS.md) is out of scope for this slice, and the
  # dropdowns never consumed those fields anyway.

  @doc """
  Returns the Equipment Category and Container options for the Inventory
  Item list filter dropdowns.

  Both lists are ordered by `name` ascending, mirroring the previous
  `orderBy("name")` behaviour. The result is a domain-shaped map with
  snake_case keys; the controller JSON renderer converts them to the
  camelCase contract (`categories`, `containers`).
  """
  @spec filter_options() :: %{
          categories: [map()],
          containers: [map()]
        }
  def filter_options do
    categories =
      Repo.all(
        from c in EquipmentCategory,
          order_by: [asc: c.name],
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            available_attributes: c.available_attributes,
            attribute_schema: c.attribute_schema
          }
      )

    containers =
      Repo.all(
        from c in Container,
          order_by: [asc: c.name],
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            parent_container_id: c.parent_container_id
          }
      )

    %{categories: categories, containers: containers}
  end

  # ── Equipment Category list (ALE-96) ──────────────────────────────────
  #
  # Returns the domain-shaped Equipment Category list, each with its
  # Inventory Item count, ordered by `name` ascending. Replaces the
  # SvelteKit client-side Supabase/PostgREST read over `equipment_categories`
  # (with an `equipment_items(count)` aggregate) on the Inventory categories
  # dashboard (`src/routes/dashboard/inventory/categories/+page.svelte`).
  #
  # The item count is a left-joined aggregate so categories with no Inventory
  # Items still appear (with `item_count: 0`), mirroring the previous
  # `equipment_items(count)` PostgREST aggregate. `count(i.id)` counts
  # non-null `inventory_items.id` rows, so a category with no items yields
  # `0` rather than `1` (a bare `count(*)` over the left join would produce
  # `1` for the synthetic null row).

  @doc """
  Returns the domain-shaped Equipment Category list with Inventory Item
  counts, ordered by `name` ascending.

  The result is a domain-shaped map with snake_case keys; the controller JSON
  renderer converts them to the camelCase contract (`categories`). Each
  category carries `id`, `name`, `description`, `available_attributes`, and
  `item_count`. Internal timestamps and auth-user refs are not exposed.
  """
  @spec list_categories() :: %{categories: [map()]}
  def list_categories do
    categories =
      Repo.all(
        from c in EquipmentCategory,
          left_join: i in InventoryItem,
          on: i.category_id == c.id,
          order_by: [asc: c.name],
          group_by: c.id,
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            available_attributes: c.available_attributes,
            item_count: count(i.id)
          }
      )

    %{categories: categories}
  end

  # ── Container list (ALE-97) ───────────────────────────────────────────
  #
  # Returns the flat, domain-shaped Container list, each with its parent
  # Container (the nested `{ id, name }` object, or `nil` for a top-level
  # Container) and the number of Inventory Items directly in it, ordered by
  # `name` ascending. Replaces the SvelteKit client-side Supabase/PostgREST
  # read over `containers` (with a `parent_container:containers!fk(id, name)`
  # join and an `equipment_items(count)` aggregate) on the Inventory
  # containers dashboard (`src/routes/dashboard/inventory/containers/+page.svelte`).
  #
  # The response is intentionally a flat array; the dashboard derives its
  # hierarchy tree client-side from `parentContainerId`/`parentContainer`.
  #
  # The item count is a left-joined `count(i.id)` over `inventory_items`
  # (constrained to `i.container_id == c.id`) so containers with no Inventory
  # Items still appear with `item_count: 0`. `count(i.id)` counts non-null
  # `inventory_items.id` rows, so an empty container yields `0` rather than
  # the `1` a bare `count(*)` over the left join would produce.
  #
  # The parent Container object is built in Elixir from the same flat list
  # (the list is the source of truth for the hierarchy) rather than via a
  # second self-join. This keeps the `count(i.id)` GROUP BY free of parent
  # columns (a self-join would force the parent's `id`/`name` into the GROUP
  # BY, or require a subquery), and it gracefully yields `nil` for a missing
  # parent (e.g. a stale `parent_container_id` after a parent delete).

  @doc """
  Returns the flat, domain-shaped Container list with parent Container data
  and Inventory Item counts, ordered by `name` ascending.

  The result is a domain-shaped map with snake_case keys; the controller JSON
  renderer converts them to the camelCase contract (`containers`). Each
  container carries `id`, `name`, `description`, `parent_container_id`,
  `parent_container` (the nested `%{id, name}` map, or `nil`), and
  `item_count`. Internal timestamps and auth-user refs are not exposed.

  The response is a flat array; the dashboard derives its hierarchy tree
  client-side from `parent_container_id`/`parent_container`. The
  `parent_container` object is built in Elixir from the same list — the list
  is the source of truth for the hierarchy — so a missing parent yields
  `nil` rather than raising.
  """
  @spec list_containers() :: %{containers: [map()]}
  def list_containers do
    rows =
      Repo.all(
        from c in Container,
          left_join: i in InventoryItem,
          on: i.container_id == c.id,
          order_by: [asc: c.name],
          group_by: c.id,
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            parent_container_id: c.parent_container_id,
            parent_container: nil,
            item_count: count(i.id)
          }
      )

    # Build the nested parent_container object from the same flat list. The
    # list is the source of truth for the hierarchy: a container's parent is
    # another row in this list, so a single pass builds a `%{id => %{id,
    # name}}` lookup and attaches it to each container. A missing parent
    # (stale `parent_container_id`) stays `nil`.
    parent_by_id =
      Map.new(rows, fn row -> {row.id, %{"id" => row.id, "name" => row.name}} end)

    containers =
      Enum.map(rows, fn row ->
        parent =
          case row.parent_container_id do
            nil -> nil
            parent_id -> Map.get(parent_by_id, parent_id)
          end

        %{row | parent_container: parent}
      end)

    %{containers: containers}
  end
end
