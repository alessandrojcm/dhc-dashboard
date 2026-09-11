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
  the `:inventory_admin_api` pipeline.

  The controller maps `Dhc.Inventory` result tuples onto status codes and
  fires keyed notifications *after* a successful write. Interlock
  conflicts become `409` with a typed `code`; validation failures become
  `422`.
  """

  use DhcWeb, :controller

  require Logger

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryOperatorLoansJSON]

  @conflict_codes %{
    not_pending: "The loan is not a pending request",
    not_approved: "The loan is not approved",
    not_checked_out: "The loan is not checked out",
    not_editable: "The loan's dates are no longer editable",
    item_unavailable: "The item is not available to allocate",
    already_allocated: "Another loan already holds this item",
    start_immutable: "The start date cannot change after checkout",
    outside_window: "Today is outside the approved loan window",
    maintenance_open: "The item has an open maintenance period"
  }

  @validation_codes %{
    invalid_dates: "dates are invalid",
    invalid_note: "note must be text"
  }

  @doc """
  GET /inventory/operator/loans/:loanId
  """
  def show(conn, %{"loanId" => loan_id}) do
    loan_id |> Inventory.get_operator_loan() |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/approve
  """
  def approve(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.approve_loan(params, actor_id(conn))
    |> notify(:approved)
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/reject
  """
  def reject(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.reject_loan(params, actor_id(conn))
    |> notify(:rejected)
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/cancel
  """
  def cancel(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.cancel_operator_loan(params, actor_id(conn))
    |> notify(:cancelled)
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/checkout
  """
  def checkout(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.check_out_loan(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/return
  """
  def return(conn, %{"loanId" => loan_id}) do
    loan_id
    |> Inventory.return_loan(actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/loans/:loanId/dates
  """
  def edit_dates(conn, %{"loanId" => loan_id} = params) do
    loan_id
    |> Inventory.edit_loan_dates(params, actor_id(conn))
    |> notify_if_due_requested(params)
    |> respond(conn)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp notify({:ok, loan} = ok, kind) do
    case Inventory.notify_loan_transition(loan, kind) do
      {:ok, _outcome} -> :ok
      :ok -> :ok
      {:error, reason} -> log_notify_failure(loan, kind, reason)
    end

    ok
  end

  defp notify(error, _kind), do: error

  # Story 48: only a due-date write is news. The request names the date;
  # a restatement of the same day is absorbed by the revisioned key, and
  # a later distinct date is a new event. Nothing is decided from an
  # unlocked pre-read of the loan.
  defp notify_if_due_requested(result, params) do
    if due_requested?(params), do: notify(result, :dates_changed), else: result
  end

  defp due_requested?(params) when is_map(params) do
    Enum.any?(["dueOn", "due_on", :dueOn, :due_on], &Map.has_key?(params, &1))
  end

  defp log_notify_failure(loan, kind, reason) do
    Logger.warning(
      "[inventory] loan notification failed loan_id=#{loan.id} kind=#{kind} reason=#{inspect(reason)}"
    )
  end

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

  defp not_found(conn), do: render_error(conn, :not_found, %{detail: "Loan not found"})

  defp render_error(conn, status, assigns) do
    conn |> put_status(status) |> put_view(@view) |> render(:error, assigns)
  end

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
