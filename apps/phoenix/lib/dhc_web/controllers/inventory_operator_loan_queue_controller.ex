defmodule DhcWeb.InventoryOperatorLoanQueueController do
  @moduledoc """
  Shared operator loan queue — ALE-286c.

    * GET /inventory/operator/loans/queue — the four work-list buckets.

  Unpaginated by design: a working list rendered in full; each bucket is
  `{count, rows}` where `count` is `length(rows)`. If `requested` ever
  grows past a screen, the answer is a request cap, not pagination.
  Every holder of the `inventory.manage` capability has equal authority,
  enforced by `:inventory_manage`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryOperatorLoanQueueJSON]

  action_fallback DhcWeb.InventoryHTTP

  @doc """
  GET /inventory/operator/loans/queue
  """
  def show(conn, _params) do
    conn
    |> put_view(@view)
    |> render(:show, queue: Inventory.get_operator_loan_queue())
  end
end
