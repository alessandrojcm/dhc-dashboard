defmodule DhcWeb.InventoryHistoryJSON do
  @moduledoc false

  def render("index.json", %{inventory_histories: inventory_histories}) do
    %{data: Enum.map(inventory_histories, &render_inventory_history/1)}
  end

  defp render_inventory_history(%Dhc.Inventory.InventoryHistory{} = inventory_history) do
    %{
      history: inventory_history.history,
      limit: inventory_history.limit
    }
  end
end
