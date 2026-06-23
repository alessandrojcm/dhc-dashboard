defmodule DhcWeb.InventoryController do
  use DhcWeb, :controller

  alias Dhc.Inventory

  @moduledoc """
  Inventory management reads.

  All actions are protected by the `:inventory_admin_api` pipeline
  (`quartermaster`, `president`, `admin`) — see `Dhc.Inventory` for the
  canonical Inventory management roles and the rationale for mirroring the
  existing dashboard Inventory gate.

  This slice covers the overview counts (ALE-94), the Inventory Activity
  feed (ALE-95), and the Inventory Item filter options (ALE-98). Later
  Inventory endpoint slices (categories, containers, items — see PRD #93)
  will extend this controller.
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

  @doc """
  GET /inventory/activity

  Returns the cursor-paginated Inventory Activity feed (the
  `inventory_history` table), newest-first, with no total count. Supports
  `itemId` and `containerId` filters and an opaque `cursor`. Replaces the
  SvelteKit server-side PostgREST/Kysely read over `inventory_history`
  joined to `inventory_items` and `containers` on the Inventory dashboard
  overview (`src/routes/dashboard/inventory/+page.server.ts`).
  """
  def activity(conn, params) do
    case Inventory.list_activity(params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.InventoryJSON)
        |> render(:activity, result: result)

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or mismatched cursor")

      {:error, :invalid_limit} ->
        bad_request(conn, "Invalid limit")

      {:error, :bad_item_id} ->
        bad_request(conn, "Invalid itemId")

      {:error, :bad_container_id} ->
        bad_request(conn, "Invalid containerId")

      {:error, _reason} ->
        bad_request(conn, "Invalid inventory activity query")
    end
  end

  @doc """
  GET /inventory/items/filters

  Returns the Equipment Category and Container options used to populate the
  Inventory Item list filter dropdowns, replacing the SvelteKit server-side
  `getFilterOptions()` read (`item.service.ts`). Both lists are ordered by
  `name` ascending. The item rows themselves remain on the existing read
  until the item-list slice (PRD #93) lands.
  """
  def filters(conn, _params) do
    options = Inventory.filter_options()

    conn
    |> put_view(json: DhcWeb.InventoryJSON)
    |> render(:filters, options: options)
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
