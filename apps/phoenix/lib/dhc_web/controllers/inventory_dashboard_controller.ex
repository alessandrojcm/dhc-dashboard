defmodule DhcWeb.InventoryDashboardController do
  @moduledoc false

  use DhcWeb, :controller

  alias Dhc.Inventory

  def stats(conn, _params) do
    render(conn, :stats, stats: Inventory.get_stats())
  end
end
