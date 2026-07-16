defmodule DhcWeb.InventoryDashboardJSON do
  @moduledoc false

  def stats(%{stats: stats}) do
    %{data: stats}
  end
end
