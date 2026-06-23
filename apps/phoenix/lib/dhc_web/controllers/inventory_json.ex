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

  # Expose the canonical Inventory management roles so controllers/tests can
  # reference the same source of truth as the context (see Dhc.Inventory).
  defdelegate inventory_management_roles, to: Inventory
end
