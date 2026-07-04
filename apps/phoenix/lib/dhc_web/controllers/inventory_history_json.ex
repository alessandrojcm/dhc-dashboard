defmodule DhcWeb.InventoryHistoryJSON do
  @moduledoc false

  def render("index.json", %{history: history, limit: limit}) do
    %{data: %{history: Enum.map(history, &render_inventory_history/1), limit: limit}}
  end

  defp render_inventory_history(%Dhc.Inventory.InventoryHistory{} = h) do
    %{
      id: h.id,
      itemId: h.item_id,
      action: h.action,
      oldContainerId: h.old_container_id,
      newContainerId: h.new_container_id,
      oldContainer: h.old_container,
      newContainer: h.new_container,
      item: h.item,
      notes: h.notes,
      changedBy: h.changed_by,
      createdAt: serialize_datetime(h.created_at)
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
