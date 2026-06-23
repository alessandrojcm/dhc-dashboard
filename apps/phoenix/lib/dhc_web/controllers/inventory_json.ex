defmodule DhcWeb.InventoryJSON do
  @moduledoc false

  alias Dhc.Inventory

  @doc """
  GET /inventory/overview — Inventory overview summary counts.

  Renders the four counts as a camelCase `summary` object inside `data`,
  matching the OpenAPI contract (`InventoryOverviewResponse`):
  `summary.containerCount`, `summary.categoryCount`, `summary.itemCount`,
  and `summary.maintenanceCount`.
  """
  def render("overview.json", %{summary: summary}) do
    %{
      data: %{
        summary: %{
          containerCount: summary.container_count,
          categoryCount: summary.category_count,
          itemCount: summary.item_count,
          maintenanceCount: summary.maintenance_count
        }
      }
    }
  end

  @doc """
  GET /inventory/activity — Inventory Activity feed.

  Renders the cursor-paginated activity entries as a camelCase `activity`
  array inside `data`, plus `limit` and `nextCursor` (or `null`). Matches the
  OpenAPI contract (`InventoryActivityListResponse`). No total count is
  returned. Each entry's nested `item`/`oldContainer`/`newContainer` objects
  are built in the context query (as JSON via `json_build_object`) and
  passed through unchanged; `nil` stays `nil`.
  """
  def render("activity.json", %{result: result}) do
    %{
      data: %{
        activity: Enum.map(result.activity, &activity_entry/1),
        limit: result.limit,
        nextCursor: result.next_cursor
      }
    }
  end

  defp activity_entry(entry) do
    %{
      id: entry.id,
      action: entry.action,
      changedBy: entry.changed_by,
      createdAt: entry.created_at,
      itemId: entry.item_id,
      oldContainerId: entry.old_container_id,
      newContainerId: entry.new_container_id,
      notes: entry.notes,
      item: entry.item,
      oldContainer: entry.old_container,
      newContainer: entry.new_container
    }
  end

  @doc """
  GET /inventory/items/filters — Inventory Item filter options.

  Renders the Equipment Category and Container dropdown options as
  camelCase `categories` and `containers` arrays inside `data`, matching
  the OpenAPI contract (`InventoryItemFiltersResponse`). Mirrors the
  previous `getFilterOptions()` `selectAll()` payloads, camelCased;
  internal timestamps and auth-user refs are not exposed.
  """
  def render("filters.json", %{options: options}) do
    %{
      data: %{
        categories: Enum.map(options.categories, &filter_category/1),
        containers: Enum.map(options.containers, &filter_container/1)
      }
    }
  end

  defp filter_category(category) do
    %{
      id: category.id,
      name: category.name,
      description: category.description,
      availableAttributes: category.available_attributes,
      attributeSchema: category.attribute_schema
    }
  end

  defp filter_container(container) do
    %{
      id: container.id,
      name: container.name,
      description: container.description,
      parentContainerId: container.parent_container_id
    }
  end

  @doc """
  GET /inventory/categories — Equipment Category list with item counts.

  Renders the Equipment Categories as a camelCase `categories` array inside
  `data`, matching the OpenAPI contract (`InventoryCategoryListResponse`).
  Each category carries `id`, `name`, `description`, `availableAttributes`,
  and `itemCount`. Categories with no Inventory Items still appear with
  `itemCount: 0`. Internal timestamps and auth-user refs are not exposed.
  """
  def render("categories.json", %{result: result}) do
    %{
      data: %{
        categories: Enum.map(result.categories, &category_entry/1)
      }
    }
  end

  defp category_entry(category) do
    %{
      id: category.id,
      name: category.name,
      description: category.description,
      availableAttributes: category.available_attributes,
      itemCount: category.item_count
    }
  end

  @doc """
  GET /inventory/containers — flat Container list with parent and item counts.

  Renders the Containers as a camelCase `containers` array inside `data`,
  matching the OpenAPI contract (`InventoryContainerListResponse`). Each
  container carries `id`, `name`, `description`, `parentContainerId`,
  `parentContainer` (the nested `%{id, name}` object, or `nil` for a
  top-level Container), and `itemCount`. Containers with no Inventory Items
  still appear with `itemCount: 0`. Internal timestamps and auth-user refs are
  not exposed.
  """
  def render("containers.json", %{result: result}) do
    %{
      data: %{
        containers: Enum.map(result.containers, &container_entry/1)
      }
    }
  end

  defp container_entry(container) do
    %{
      id: container.id,
      name: container.name,
      description: container.description,
      parentContainerId: container.parent_container_id,
      parentContainer: container.parent_container,
      itemCount: container.item_count
    }
  end

  @doc """
  GET /inventory/items — Inventory Item list with total count.

  Renders the cursor-paginated Inventory Items as a camelCase `items` array
  inside `data`, plus `limit`, `totalCount`, `nextCursor`, and
  `previousCursor`, matching the OpenAPI contract (`InventoryItemListResponse`).
  Each item carries `id`, `quantity`, `maintenanceStatus` (`available` or
  `inMaintenance` — the domain term for the persistence `out_for_maintenance`
  boolean), `attributes`, and the nested `category`/`container` `{ id, name }`
  objects (or `null`). Internal auth-user refs and timestamps are not exposed.
  """
  def render("items.json", %{result: result}) do
    %{
      data: %{
        items: Enum.map(result.items, &item_entry/1),
        limit: result.limit,
        totalCount: result.total_count,
        nextCursor: result.next_cursor,
        previousCursor: result.previous_cursor
      }
    }
  end

  defp item_entry(item) do
    %{
      id: item.id,
      quantity: item.quantity,
      maintenanceStatus: item.maintenance_status,
      attributes: item.attributes,
      category: item.category,
      container: item.container
    }
  end

  # Expose the canonical Inventory management roles so controllers/tests can
  # reference the same source of truth as the context (see Dhc.Inventory).
  defdelegate inventory_management_roles, to: Inventory
end
