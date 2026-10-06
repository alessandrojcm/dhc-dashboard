defmodule DhcWeb.InventoryOperatorLoansController do
  @moduledoc """
  Operator viewers and commands for Loans — ALE-286c.

    * GET  /inventory/operator/loans/:loanId           — show, write roles.
    * POST /inventory/operator/loans/:loanId/approve   — approve, write roles.
    * POST /inventory/operator/loans/:loanId/reject    — reject, write roles.
    * POST /inventory/operator/loans/:loanId/cancel    — operator cancel, write roles.
    * POST /inventory/operator/loans/:loanId/checkout  — checkout, write roles.
    * POST /inventory/operator/loans/:loanId/return    — return, write roles.
    * POST /inventory/operator/loans/:loanId/dates     — edit dates, write roles.

  Every command is its own action with its own request body, so there is
  no generic loan patch that can move lifecycle state. Operator authority
  is equal for `quartermaster`, `president`, and `admin`, all enforced by
  the `:inventory_manage` pipeline.

  The controller renders successes (`DhcWeb.InventoryHTTP` maps every
  error) and enqueues keyed notifications *after* a successful write. The command
  has already committed; `Dhc.Notifications.Workers.KeyedCreateWorker`
  (queue `:notifications`) calls `create_keyed/3` with retries so a
  failed create cannot permanently lose the row. Enqueue failure is a
  `500` before the client is told the transition succeeded. Interlock
  conflicts become `409` with a typed `code`; validation failures become
  `422`.
  """

  use DhcWeb, :controller

  require Logger

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryOperatorLoansJSON]

  # Domain atoms whose operator wording differs from the member catalog's
  # in the shared `DhcWeb.InventoryHTTP` table.
  @operator_reasons %{
    not_found: :loan_not_found,
    item_unavailable: :allocation_unavailable,
    invalid_dates: :invalid_loan_dates
  }

  @doc """
  GET /inventory/operator/loans/:loanId
  """
  def show(conn, %{"loanId" => loan_id}) do
    loan_id |> Inventory.get_operator_loan() |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/approve
  """
  def approve(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.approve_loan(params, actor_id(conn))
    |> notify(:approved)
    |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/reject
  """
  def reject(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.reject_loan(params, actor_id(conn))
    |> notify(:rejected)
    |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/cancel
  """
  def cancel(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.cancel_operator_loan(params, actor_id(conn))
    |> notify(:cancelled)
    |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/checkout
  """
  def checkout(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.check_out_loan(params, actor_id(conn))
    |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/return
  """
  def return(conn, %{"loanId" => loan_id}) do
    loan_id
    |> Inventory.return_loan(actor_id(conn))
    |> render_loan(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/dates
  """
  def edit_dates(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.edit_loan_dates(params, actor_id(conn))
    |> notify_if_due_requested(params)
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
        log_notify_failure(loan, kind, reason)
        {:error, :notification_enqueue_failed}
    end
  end

  defp notify(error, _kind), do: error

  # Story 48: only a moved due date is news. The command result carries
  # the previous due date from under the item lock; a restatement of the
  # same day does not enqueue. Nothing is decided from an unlocked
  # pre-read of the loan.
  defp notify_if_due_requested({:ok, loan} = ok, params) do
    if due_moved?(loan, params), do: notify(ok, :dates_changed), else: ok
  end

  defp notify_if_due_requested(error, _params), do: error

  defp due_moved?(loan, params) when is_map(params) do
    due_requested?(params) and Map.get(loan, :previous_due_on) != loan.approved_due_on
  end

  defp due_requested?(params) when is_map(params) do
    Enum.any?(["dueOn", "due_on", :dueOn, :due_on], &Map.has_key?(params, &1))
  end

  defp log_notify_failure(loan, kind, reason) do
    Logger.warning(
      "[inventory] loan notification enqueue failed loan_id=#{loan.id} kind=#{kind} reason=#{inspect(reason)}"
    )
  end

  defp render_loan({:ok, loan}, conn), do: conn |> put_view(@view) |> render(:show, loan: loan)

  defp render_loan({:error, reason}, _conn) when is_map_key(@operator_reasons, reason),
    do: {:error, Map.fetch!(@operator_reasons, reason)}

  defp render_loan(error, _conn), do: error

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
