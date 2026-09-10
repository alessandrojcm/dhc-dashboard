defmodule DhcWeb.InventoryOperatorItemsJSON do
  @moduledoc false

  # ALE-284c operator item viewer renderer.
  #
  # Top-level envelope:
  #   * list        → `%{data: %{items: [...], totalCount:, limit:,
  #                    nextCursor:, previousCursor:}}`
  #   * single      → `%{data: %{...}}`
  #   * maintenance → `%{data: %{periods: [...]}}`
  #   * error       → `%{errors: %{detail:, code?:, valueErrors?:}}`
  #
  # The viewer deliberately omits the legacy and internal columns the target
  # item never uses: `quantity`, `photoUrl`, `attributes`,
  # `outForMaintenance`, `createdBy`, `updatedBy`, and the raw timestamps.
  # `label` and `availability` are projections computed on read
  # (`Dhc.Inventory.ItemProjection`), never stored fields.

  alias Dhc.Inventory.Item

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

  def render("show.json", %{item: item}) do
    %{data: render_item(item)}
  end

  def render("maintenance.json", %{periods: periods}) do
    %{data: %{periods: Enum.map(periods, &render_period/1)}}
  end

  def render("error.json", assigns) do
    errors =
      assigns
      |> Map.take([:detail, :code, :valueErrors])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> render_value_errors()

    %{errors: errors}
  end

  # Per-definition reasons are atoms in the domain; the contract types them
  # as strings keyed by definition id.
  defp render_value_errors(%{valueErrors: value_errors} = errors) when is_map(value_errors) do
    %{errors | valueErrors: Map.new(value_errors, fn {id, reason} -> {id, to_string(reason)} end)}
  end

  defp render_value_errors(errors), do: errors

  defp render_item(%Item{} = item) do
    %{
      id: item.id,
      slug: item.slug,
      label: item.label,
      categoryId: item.category_id,
      containerId: item.container_id,
      category: render_summary(item.category),
      container: render_summary(item.container),
      values: Enum.map(item.values || [], &render_value/1),
      notes: item.notes,
      availability: render_availability(item.availability),
      archivedAt: serialize_datetime(item.archived_at)
    }
  end

  # Container and category summaries arrive from the projection with string
  # keys; map them explicitly so the wire shape cannot drift with the query.
  defp render_summary(nil), do: nil

  defp render_summary(summary) when is_map(summary) do
    %{
      id: summary["id"],
      name: summary["name"],
      archivedAt: serialize_datetime(summary["archived_at"])
    }
  end

  defp render_availability(nil), do: nil

  defp render_availability(%{available?: available?, status: status}) do
    %{available: available?, status: to_string(status)}
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

  defp render_period(period) do
    %{
      id: period.id,
      itemId: period.item_id,
      startedAt: serialize_datetime(period.started_at),
      startedByPrincipalId: period.started_by_principal_id,
      startReason: period.start_reason,
      endedAt: serialize_datetime(period.ended_at),
      endedByPrincipalId: period.ended_by_principal_id,
      endNote: period.end_note,
      open: period.open?
    }
  end

  # Decimals serialize as strings so no precision is lost in JSON.
  defp serialize_decimal(nil), do: nil
  defp serialize_decimal(%Decimal{} = decimal), do: Decimal.to_string(decimal)

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end
end
