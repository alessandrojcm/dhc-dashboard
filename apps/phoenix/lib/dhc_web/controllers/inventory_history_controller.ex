defmodule DhcWeb.InventoryHistoryController do
  @moduledoc """
  Global inventory activity feed — ALE-108.

    * GET /inventory/history — recent `inventory_history` rows across all
      items, newest first, each with `oldContainer`/`newContainer` name
      summaries and an `item` summary (`%{id, attributes}`). Any authenticated
      member may read.

  The controller does no business logic; it delegates to
  `Dhc.Inventory.list_history/1` and reuses `DhcWeb.InventoryItemsJSON`'s
  `:history` renderer so the wire shape matches the per-item history endpoint
  (`InventoryItemHistoryListResponse`).
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @doc """
  GET /inventory/history
  """
  def index(conn, params) do
    case Inventory.list_history(params) do
      {:ok, history} ->
        limit = history_limit(params)

        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:history, history: history, limit: limit)

      _ ->
        bad_request(conn, "Invalid request")
    end
  end

  defp history_limit(%{"limit" => limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> n
      _ -> 50
    end
  end

  defp history_limit(%{"limit" => limit}) when is_integer(limit), do: limit
  defp history_limit(_), do: 50

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:error, detail: detail)
  end
end
