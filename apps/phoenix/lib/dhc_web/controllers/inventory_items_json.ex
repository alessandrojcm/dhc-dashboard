defmodule DhcWeb.InventoryItemsJSON do
  @moduledoc false

  # ALE-104 Inventory REST contract renderer for the item slice.
  #
  # Top-level envelope:
  #   * collection → `%{data: %{items: [...], limit: n, nextCursor: ...}}`
  #     (InventoryItemListResponse)
  #   * flat single (create/update/show) → `%{data: %{...}}`
  #     (InventoryItemResponse)
  #   * history    → `%{data: %{history: [...], limit: n}}`
  #     (InventoryItemHistoryListResponse)
  #   * error      → `%{errors: %{detail: ...}}`        (Error)
  #
  # Payload keys are camelCase per the contract: `containerId`, `categoryId`,
  # `outForMaintenance`, `photoUrl`, `createdAt`, `updatedAt`, `createdBy`,
  # `updatedBy`, `itemId`, `oldContainerId`, `newContainerId`, `oldContainer`,
  # `newContainer`, `changedBy`. The virtual summary maps (`container`,
  # `category`) come back from `Dhc.Inventory` with string keys already (see
  # `container_summary/1`, `category_summary/1`, `list_item_history/2`); they
  # are passed through verbatim so the wire shape matches the contract.

  def render("index.json", %{items: items, limit: limit, next_cursor: next_cursor}) do
    %{data: %{items: Enum.map(items, &render_item/1), limit: limit, nextCursor: next_cursor}}
  end

  # Single flat item — create/update/show responses.
  def render("item.json", %{item: item}) do
    %{data: render_item(item)}
  end

  # 412 Precondition Failed — ADR 0023 Phase 1.2 (ALE-266): the current
  # server entity rides alongside the error detail so the client can
  # reconcile, reusing the response envelope.
  def render("precondition_failed.json", %{item: item}) do
    %{data: render_item(item), errors: %{detail: "version precondition failed"}}
  end

  # Item history collection.
  def render("history.json", %{history: history, limit: limit}) do
    %{data: %{history: Enum.map(history, &render_history/1), limit: limit}}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  defp render_item(%Dhc.Inventory.Item{} = item) do
    %{
      id: item.id,
      containerId: item.container_id,
      categoryId: item.category_id,
      quantity: item.quantity,
      outForMaintenance: item.out_for_maintenance,
      attributes: item.attributes || %{},
      notes: item.notes,
      photoUrl: item.photo_url,
      container: item.container,
      category: item.category,
      createdBy: item.created_by,
      updatedBy: item.updated_by,
      lockVersion: item.lock_version,
      createdAt: serialize_datetime(item.created_at),
      updatedAt: serialize_datetime(item.updated_at)
    }
  end

  defp render_history(%Dhc.Inventory.InventoryHistory{} = h) do
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

  # `:utc_datetime_usec` / `:utc_datetime` Ecto types may load as
  # `%NaiveDateTime{}` via Postgrex depending on the column type; cover it so
  # the wire shape carries a canonical ISO-8601 string in either case.
  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
