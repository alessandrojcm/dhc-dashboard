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

  # Expose the canonical Inventory management roles so controllers/tests can
  # reference the same source of truth as the context (see Dhc.Inventory).
  defdelegate inventory_management_roles, to: Inventory
end