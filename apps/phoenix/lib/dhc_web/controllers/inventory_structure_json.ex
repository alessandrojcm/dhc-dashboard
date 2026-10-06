defmodule DhcWeb.InventoryStructureJSON do
  @moduledoc false

  # ALE-283c operator structure viewer renderer.
  #
  # Top-level envelope (errors render through `DhcWeb.InventoryHTTP`):
  #   * collection → `%{data: %{definitions: [...]}}` or `%{data: %{options: [...]}}`
  #   * single     → `%{data: %{...}}`

  import DhcWeb.JSONHelpers, only: [serialize_datetime: 1]

  def render("index.json", %{definitions: definitions}) do
    %{data: %{definitions: Enum.map(definitions, &render_definition/1)}}
  end

  def render("show.json", %{definition: definition}) do
    %{data: render_definition(definition)}
  end

  def render("options.json", %{options: options}) do
    %{data: %{options: Enum.map(options, &render_option/1)}}
  end

  def render("option.json", %{option: option}) do
    %{data: render_option(option)}
  end

  defp render_definition(%Dhc.Inventory.PropertyDefinition{} = definition) do
    %{
      id: definition.id,
      categoryId: definition.category_id,
      label: definition.label,
      valueType: definition.value_type,
      required: definition.required,
      identifyingPosition: definition.identifying_position,
      retiredAt: serialize_datetime(definition.retired_at),
      options: Enum.map(definition.options || [], &render_option/1)
    }
  end

  defp render_option(%Dhc.Inventory.PropertyOption{} = option) do
    %{
      id: option.id,
      propertyDefinitionId: option.property_definition_id,
      label: option.label,
      position: option.position,
      retiredAt: serialize_datetime(option.retired_at)
    }
  end
end
