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
  and every operator transition live on `/inventory/operator/loans*`
  (ALE-298); nothing here can be reached with an operator role that a
  plain member could not reach.

  The controller renders successes and enqueues keyed operator notifications
  after a successful cancel; a missing loan becomes `:loan_not_found` and
  `DhcWeb.InventoryHTTP` maps every error.
  Enqueue failure is a `500` before the client is told the cancel succeeded.
  """

  use DhcWeb, :controller

  require Logger

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryMemberLoansJSON]

  @doc """
  GET /inventory/loans/mine
  """
  def list(conn, params) do
    with {:ok, page} <- Inventory.list_own_loans(actor_id(conn), params) do
      conn |> put_view(@view) |> render(:index, page: page)
    end
  end

  @doc """
  GET /inventory/loans/mine/:loanId
  """
  def show(conn, %{"loanId" => loan_id}) do
    loan_id |> Inventory.get_own_loan(actor_id(conn)) |> render_loan(conn)
  end

  @doc """
  POST /inventory/loans/mine/:loanId/cancel
  """
  def cancel(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.cancel_loan(params, actor_id(conn))
    |> notify(:member_cancelled)
    |> render_loan(conn)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp notify({:ok, loan} = ok, kind) do
    case Inventory.notify_loan_transition(loan, kind) do
      {:ok, :enqueued} ->
        ok

      :ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "[inventory] loan notification enqueue failed loan_id=#{loan.id} kind=#{kind} reason=#{inspect(reason)}"
        )

        {:error, :notification_enqueue_failed}
    end
  end

  defp notify(error, _kind), do: error

  defp render_loan({:ok, loan}, conn), do: conn |> put_view(@view) |> render(:show, loan: loan)
  defp render_loan({:error, :not_found}, _conn), do: {:error, :loan_not_found}
  defp render_loan(error, _conn), do: error

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
