defmodule DhcWeb.InventoryOperatorLoanQueueController do
  @moduledoc """
  Shared operator loan queue — ALE-286c.

    * GET /inventory/operator/loans/queue — the four work-list buckets.

  Unpaginated by design: a working list rendered in full; each bucket is
  `{count, rows}` where `count` is `length(rows)`. If `requested` ever
  grows past a screen, the answer is a request cap, not pagination.
  Operator authority is equal for `quartermaster`, `president`, and
  `admin`, enforced by `:inventory_admin_api`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryOperatorLoanQueueJSON]

  @doc """
  GET /inventory/operator/loans/queue
  """
  def show(conn, _params) do
    conn
    |> put_view(@view)
    |> render(:show, queue: Inventory.get_operator_loan_queue())
  end
end
