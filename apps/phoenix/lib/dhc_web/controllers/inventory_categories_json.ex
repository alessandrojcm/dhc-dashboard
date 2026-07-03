defmodule DhcWeb.InventoryCategoriesJSON do
  @moduledoc false

  # ALE-104 Inventory REST contract renderer.
  #
  # Top-level envelope:
  #   * collection → `%{data: %{categories: [...]}}` (InventoryCategoryListResponse)
  #   * single     → `%{data: %{...}}`              (InventoryCategoryResponse)
  #   * error      → `%{errors: %{detail: ...}}`     (Error)
  #
  # Payload keys are camelCase per the contract: `availableAttributes`,
  # `itemCount`, `createdAt`, `updatedAt`. The `availableAttributes` element
  # maps are passed through verbatim — the persistence layer (and the old
  # Svelte service) store attribute definitions with their own keys
  # (`name`/`label`/`type`/`required`/`options`, and historically
  # `default_value`); the contract's `defaultValue` is the canonical name but
  # elements are intentionally not reshaped here so existing rows round-trip
  # without data loss. Once item-attribute validation lands, the element shape
  # can be normalized at the schema boundary.

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
      availableAttributes: category.available_attributes || [],
      itemCount: category.item_count || 0,
      createdAt: serialize_datetime(category.created_at),
      updatedAt: serialize_datetime(category.updated_at)
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # `:utc_datetime` Ecto type loads as a naive `%DateTime{}`-ish struct via
  # Postgrex when the column is timestamptz — cover the `%NaiveDateTime{}` case
  # too in case the adapter returns naive values.
  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
