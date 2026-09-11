defmodule DhcWeb.InventoryOperatorLoanQueueJSON do
  @moduledoc false

  # ALE-286c operator loan queue renderer.
  #
  # Envelope: `%{data: %{pendingRequests:, handoversDue:,
  # returnsAndOverdue:, openMaintenance:}}`. Each bucket is
  # `{count, rows}` with `count == length(rows)`.
  #
  # Loan rows go through the operator loan renderer so a queue row and
  # the show projection cannot disagree. Handover rows add the advisory
  # `readyForCheckout` flag on top.

  alias DhcWeb.InventoryOperatorLoansJSON

  def render("show.json", %{queue: queue}) do
    %{
      data: %{
        pendingRequests: render_loan_bucket(queue.pending_requests),
        handoversDue: render_handover_bucket(queue.handovers_due),
        returnsAndOverdue: render_loan_bucket(queue.returns_and_overdue),
        openMaintenance: render_maintenance_bucket(queue.open_maintenance)
      }
    }
  end

  defp render_loan_bucket(%{count: count, rows: rows}) do
    %{count: count, rows: Enum.map(rows, &InventoryOperatorLoansJSON.render_loan/1)}
  end

  defp render_handover_bucket(%{count: count, rows: rows}) do
    %{
      count: count,
      rows:
        Enum.map(rows, fn row ->
          row
          |> InventoryOperatorLoansJSON.render_loan()
          |> Map.put(:readyForCheckout, row.ready_for_checkout?)
        end)
    }
  end

  defp render_maintenance_bucket(%{count: count, rows: rows}) do
    %{count: count, rows: Enum.map(rows, &render_maintenance/1)}
  end

  defp render_maintenance(row) do
    %{
      id: row.id,
      itemId: row.item_id,
      itemSlug: row.item_slug,
      itemLabel: row.item_label,
      startedAt: serialize_datetime(row.started_at),
      startedByPrincipalId: row.started_by_principal_id,
      startReason: row.start_reason
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end
end
