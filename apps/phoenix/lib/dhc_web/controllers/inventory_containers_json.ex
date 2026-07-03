defmodule DhcWeb.InventoryContainersJSON do
  @moduledoc false

  # ALE-104 Inventory REST contract renderer for the container slice.
  #
  # Top-level envelope:
  #   * collection → `%{data: %{containers: [...]}}`  (InventoryContainerListResponse)
  #   * flat single (create/update) → `%{data: %{...}}` (InventoryContainerListItemResponse)
  #   * detail single (show) → `%{data: %{...}}`        (InventoryContainerDetailResponse)
  #   * error      → `%{errors: %{detail: ...}}`        (Error)
  #
  # Payload keys are camelCase per the contract: `parentContainerId`,
  # `parentContainer`, `childContainers`, `itemCount`, `createdAt`,
  # `updatedAt`, `outForMaintenance`. The virtual summary maps
  # (`parent_container`, `child_containers`, `items`) come back from
  # `Dhc.Inventory` with string keys already (see `parent_summary/1`,
  # `list_child_summaries/1`, `list_container_items/1`); they are passed
  # through verbatim so the wire shape matches the contract.

  def render("index.json", %{containers: containers}) do
    %{data: %{containers: Enum.map(containers, &render_container/1)}}
  end

  # Single flat container — create/update responses.
  def render("item.json", %{container: container}) do
    %{data: render_container(container)}
  end

  # Detail (parent + children + items) — show response.
  def render("show.json", %{container: container}) do
    %{data: render_detail(container)}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  defp render_container(%Dhc.Inventory.Container{} = container) do
    %{
      id: container.id,
      name: container.name,
      description: container.description,
      parentContainerId: container.parent_container_id,
      parentContainer: container.parent_container,
      itemCount: container.item_count || 0,
      createdAt: serialize_datetime(container.created_at),
      updatedAt: serialize_datetime(container.updated_at)
    }
  end

  defp render_detail(%Dhc.Inventory.Container{} = container) do
    %{
      id: container.id,
      name: container.name,
      description: container.description,
      parentContainerId: container.parent_container_id,
      parentContainer: container.parent_container,
      childContainers: container.child_containers || [],
      items: Enum.map(container.items || [], &render_item/1),
      itemCount: container.item_count || 0,
      createdAt: serialize_datetime(container.created_at),
      updatedAt: serialize_datetime(container.updated_at)
    }
  end

  defp render_item(%{
         "id" => id,
         "quantity" => quantity,
         "out_for_maintenance" => out,
         "category" => category
       }) do
    %{
      id: id,
      quantity: quantity,
      outForMaintenance: out,
      category: category
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # `:utc_datetime` Ecto type loads as a naive struct via Postgrex when the
  # column is timestamptz — cover the `%NaiveDateTime{}` case too in case the
  # adapter returns naive values.
  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
