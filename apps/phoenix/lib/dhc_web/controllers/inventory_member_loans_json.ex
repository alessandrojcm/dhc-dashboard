defmodule DhcWeb.InventoryMemberLoansJSON do
  @moduledoc false

  # ALE-285 member loan renderer.
  #
  # Top-level envelope:
  #   * list  → `%{data: %{loans: [...]}}`
  #   * loan  → `%{data: %{...}}`
  #   * error → `%{errors: %{detail:, code?:}}`
  #
  # The rendered loan carries no borrower id: every row here already belongs
  # to the caller, so echoing the principal id would add nothing but a field
  # that must not appear in any other viewer. Deciding operators and
  # timestamps are likewise absent — a member sees the decision *note*, not
  # who made it (ALE-279: members need no actor-audit surface).
  #
  # `itemSlug`/`itemLabel` are the retained snapshots, so an archived item
  # still renders. `containerPath` arrives already gated by
  # `Dhc.Inventory.MemberLoans`, which returns it only from approval onward.

  def render("index.json", %{page: page}) do
    %{
      data: %{
        loans: Enum.map(page.loans, &render_loan/1),
        totalCount: page.total_count,
        limit: page.limit,
        nextCursor: page.next_cursor,
        previousCursor: page.previous_cursor
      }
    }
  end

  def render("show.json", %{loan: loan}), do: %{data: render_loan(loan)}

  def render("error.json", assigns) do
    errors =
      assigns
      |> Map.take([:detail, :code])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{errors: errors}
  end

  defp render_loan(loan) do
    %{
      id: loan.id,
      itemId: loan.item_id,
      status: loan.status,
      overdue: loan.overdue?,
      requestedStartOn: serialize_date(loan.requested_start_on),
      requestedDueOn: serialize_date(loan.requested_due_on),
      approvedStartOn: serialize_date(loan.approved_start_on),
      approvedDueOn: serialize_date(loan.approved_due_on),
      checkedOutAt: serialize_datetime(loan.checked_out_at),
      returnedAt: serialize_datetime(loan.returned_at),
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
