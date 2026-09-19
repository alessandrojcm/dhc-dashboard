defmodule DhcWeb.InventoryCategoriesJSON do
  @moduledoc false

  # ALE-104 Inventory REST contract renderer.
  #
  # Top-level envelope:
  #   * collection → `%{data: %{categories: [...]}}` (InventoryCategoryListResponse)
  #   * single     → `%{data: %{...}}`              (InventoryCategoryResponse)
  #   * error      → `%{errors: %{detail: ...}}`     (Error)
  #
  # Payload keys are camelCase per the contract: `itemCount`, `createdAt`,
  # `updatedAt`.

  import DhcWeb.JSONHelpers, only: [serialize_datetime: 1]

  def render("index.json", %{categories: categories}) do
    %{data: %{categories: Enum.map(categories, &render_category/1)}}
  end

  def render("show.json", %{category: category}) do
    %{data: render_category(category)}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  defp render_category(%Dhc.Inventory.EquipmentCategory{} = category) do
    %{
      id: category.id,
      name: category.name,
      description: category.description,
      itemCount: category.item_count || 0,
      createdAt: serialize_datetime(category.created_at),
      updatedAt: serialize_datetime(category.updated_at)
    }
  end
end
