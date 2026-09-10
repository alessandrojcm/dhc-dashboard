defmodule DhcWeb.InventoryCatalogJSON do
  @moduledoc false

  # ALE-285 member catalog renderer.
  #
  # Top-level envelope:
  #   * list  → `%{data: %{items: [...], totalCount:, limit:, nextCursor:,
  #             previousCursor:}}`
  #   * item  → `%{data: %{...}}`
  #   * loan  → `%{data: %{...}}` (the created request)
  #   * error → `%{errors: %{detail:, code?:}}`
  #
  # The member row is built from the catalog's own map, which by construction
  # holds no container, operator note, maintenance fact, borrower, or archive
  # state. There is nothing to strip here — the privacy boundary is in
  # `Dhc.Inventory.MemberCatalog`, and this renderer only camelCases it.

  alias DhcWeb.InventoryMemberLoansJSON

  def render("index.json", %{page: page}) do
    %{
      data: %{
        items: Enum.map(page.items, &render_item/1),
        totalCount: page.total_count,
        limit: page.limit,
        nextCursor: page.next_cursor,
        previousCursor: page.previous_cursor
      }
    }
  end

  def render("show.json", %{item: item}), do: %{data: render_item(item)}

  # A created request renders through the loan renderer, so the member's own
  # loan has one wire shape whether it arrives from a request, a list, or a
  # cancellation.
  def render("loan.json", %{loan: loan}),
    do: InventoryMemberLoansJSON.render("show.json", %{loan: loan})

  def render("error.json", assigns) do
    errors =
      assigns
      |> Map.take([:detail, :code])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{errors: errors}
  end

  defp render_item(item) do
    %{
      id: item.id,
      slug: item.slug,
      label: item.label,
      category: render_category(item.category),
      values: Enum.map(item.values || [], &render_value/1),
      availability: render_availability(item.availability)
    }
  end

  defp render_category(nil), do: nil
  defp render_category(%{id: id, name: name}), do: %{id: id, name: name}

  # `reason` rather than `status`: the member vocabulary is an explanation,
  # not the operator's lifecycle state.
  defp render_availability(%{available?: available?, reason: reason}) do
    %{available: available?, reason: to_string(reason)}
  end

  defp render_value(value) do
    %{
      definitionId: value.definition_id,
      definitionLabel: value.definition_label,
      valueType: value.value_type,
      identifyingPosition: value.identifying_position,
      text: value.text,
      decimal: serialize_decimal(value.decimal),
      boolean: value.boolean,
      optionId: value.option_id,
      optionLabel: value.option_label
    }
  end

  # Decimals serialize as strings so no precision is lost in JSON.
  defp serialize_decimal(nil), do: nil
  defp serialize_decimal(%Decimal{} = decimal), do: Decimal.to_string(decimal)
end
