defmodule DhcWeb.InventoryController do
  use DhcWeb, :controller

  alias Dhc.Inventory

  @moduledoc """
  Inventory management reads.

  All actions are protected by the `:inventory_admin_api` pipeline
  (`quartermaster`, `president`, `admin`) — see `Dhc.Inventory` for the
  canonical Inventory management roles and the rationale for mirroring the
  existing dashboard Inventory gate.

  This slice covers the overview counts only. Inventory Activity (the
  `inventory_history` feed) is a separate endpoint (PRD #93, ALE-95).
  """

  @doc """
  GET /inventory/overview

  Returns the Inventory overview summary counts: the number of Containers,
  Equipment Categories, Inventory Items, and Inventory Items currently out
  for maintenance. Replaces the SvelteKit server-side PostgREST reads over
  `containers`, `equipment_categories`, and `inventory_items` on the
  Inventory dashboard overview.
  """
  def overview(conn, _params) do
    summary = Inventory.overview_counts()

    conn
    |> put_view(json: DhcWeb.InventoryJSON)
    |> render(:overview, summary: summary)
  end
end