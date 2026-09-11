defmodule DhcWeb.InventoryOperatorLoansJSON do
  @moduledoc false

  # ALE-286c operator loan renderer.
  #
  # Top-level envelope:
  #   * loan  → `%{data: %{...}}`
  #   * error → `%{errors: %{detail:, code?:}}`
  #
  # Distinct from the member loan renderer: this viewer names the
  # borrower and always carries deciding-operator and handover
  # timestamps. `overdue` is the domain's `overdue?` projected as a
  # boolean; `containerPath` is the snapshot captured at approval.

  def render("show.json", %{loan: loan}), do: %{data: render_loan(loan)}

  def render("error.json", assigns) do
    errors =
      assigns
      |> Map.take([:detail, :code])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{errors: errors}
  end

  def render_loan(loan) do
    %{
      id: loan.id,
      itemId: loan.item_id,
      borrowerPrincipalId: loan.borrower_principal_id,
      status: loan.status,
      overdue: loan.overdue?,
      requestedStartOn: serialize_date(loan.requested_start_on),
      requestedDueOn: serialize_date(loan.requested_due_on),
      approvedStartOn: serialize_date(loan.approved_start_on),
      approvedDueOn: serialize_date(loan.approved_due_on),
      checkedOutAt: serialize_datetime(loan.checked_out_at),
      returnedAt: serialize_datetime(loan.returned_at),
      decidedAt: serialize_datetime(loan.decided_at),
      decidedByPrincipalId: loan.decided_by_principal_id,
      returnedByPrincipalId: loan.returned_by_principal_id,
      requestNote: loan.request_note,
      decisionNote: loan.decision_note,
      itemSlug: loan.item_slug,
      itemLabel: loan.item_label,
      containerPath: loan.container_path,
      createdAt: serialize_datetime(loan.created_at)
    }
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_iso8601(date)

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp serialize_datetime(%NaiveDateTime{} = dt) do
    dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end
end
