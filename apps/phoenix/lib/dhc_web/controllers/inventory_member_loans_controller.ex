defmodule DhcWeb.InventoryMemberLoansController do
  @moduledoc """
  A member's own loans — ALE-285.

    * GET  /inventory/loans/mine                  — own history, any member.
    * GET  /inventory/loans/mine/:loanId          — own loan detail.
    * POST /inventory/loans/mine/:loanId/cancel   — cancel own loan.

  The `mine` segment is the authorization model made visible in the URL:
  every action here scopes to `current_session.principal.id`, and there is no
  parameter through which a member could name a different borrower. Another
  member's loan answers `404`, not `403`, because whether it exists is not a
  member-visible fact.

  Requesting an item is `DhcWeb.InventoryCatalogController` — a request is
  addressed to an item, whose availability gates it. The operator loan queue
  and every operator transition (approve, reject, checkout, return, due-date
  edits) are ALE-286 and will be their own operator-gated slice; nothing here
  can be reached with an operator role that a plain member could not reach.

  The controller only maps `Dhc.Inventory` result tuples onto status codes.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryMemberLoansJSON]

  @conflict_codes %{
    not_cancellable: "This loan can no longer be cancelled"
  }

  @validation_codes %{
    invalid_note: "note must be text"
  }

  @doc """
  GET /inventory/loans/mine
  """
  def list(conn, params) do
    case Inventory.list_own_loans(actor_id(conn), params) do
      {:ok, page} -> conn |> put_view(@view) |> render(:index, page: page)
      {:error, reason} -> render_error(conn, :bad_request, %{detail: list_error_detail(reason)})
    end
  end

  @doc """
  GET /inventory/loans/mine/:loanId
  """
  def show(conn, %{"loanId" => loan_id}) do
    loan_id |> Inventory.get_own_loan(actor_id(conn)) |> respond(conn)
  end

  @doc """
  POST /inventory/loans/mine/:loanId/cancel
  """
  def cancel(conn, %{"loanId" => loan_id} = params) do
    loan_id |> Inventory.cancel_loan(params, actor_id(conn)) |> respond(conn)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp respond({:ok, loan}, conn) do
    conn |> put_view(@view) |> render(:show, loan: loan)
  end

  defp respond({:error, :not_found}, conn), do: not_found(conn)

  defp respond({:error, reason}, conn) when is_map_key(@conflict_codes, reason) do
    render_error(conn, :conflict, %{
      detail: Map.fetch!(@conflict_codes, reason),
      code: to_string(reason)
    })
  end

  defp respond({:error, reason}, conn) when is_map_key(@validation_codes, reason) do
    render_error(conn, :unprocessable_entity, %{
      detail: Map.fetch!(@validation_codes, reason),
      code: to_string(reason)
    })
  end

  defp list_error_detail(:invalid_status), do: "status must be all, open, or closed"
  defp list_error_detail(:invalid_limit), do: "limit must be one of 10, 25, 50, 100"
  defp list_error_detail(:invalid_direction), do: "direction must be asc or desc"
  defp list_error_detail(:bad_cursor), do: "cursor does not match the current query"

  defp not_found(conn), do: render_error(conn, :not_found, %{detail: "Loan not found"})

  defp render_error(conn, status, assigns) do
    conn |> put_status(status) |> put_view(@view) |> render(:error, assigns)
  end

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
