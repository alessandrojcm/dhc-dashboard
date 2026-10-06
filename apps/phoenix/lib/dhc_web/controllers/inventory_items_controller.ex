defmodule DhcWeb.InventoryItemsController do
  @moduledoc """
  Operator viewers and commands for target inventory Items — ALE-284c.

    * GET    /inventory/items                                 — list, inventory operators.
    * POST   /inventory/items                                 — create, inventory operators.
    * GET    /inventory/items/:slugOrId                       — show, inventory operators.
    * PATCH  /inventory/items/:slugOrId                       — generic edit, inventory operators.
    * DELETE /inventory/items/:slugOrId                       — delete, inventory operators.
    * POST   /inventory/items/:slugOrId/category              — reclassify, inventory operators.
    * POST   /inventory/items/:slugOrId/move                  — move, inventory operators.
    * GET    /inventory/items/:slugOrId/maintenance           — list periods, inventory operators.
    * POST   /inventory/items/:slugOrId/maintenance/start     — start, inventory operators.
    * POST   /inventory/items/:slugOrId/maintenance/end       — end, inventory operators.
    * POST   /inventory/items/:slugOrId/archive               — archive, inventory operators.
    * POST   /inventory/items/:slugOrId/restore               — restore, inventory operators.

  Every command is its own action with its own request body, so the generic
  edit cannot express a move, a maintenance transition, an archive, or a
  loan change. Every holder of the `inventory.manage` capability has
  equal authority, enforced by the `:inventory_manage` pipeline.

  **Reads are operator-only too.** This viewer discloses the container
  location, operator notes, and maintenance facts, which spec ALE-280 story
  45 forbids exposing to members in ordinary browsing. The member-shaped
  catalog projection — label, slug, category, values, and a generic
  unavailability reason only — is ALE-285, not a role variant of this one.

  The controller renders successes; `DhcWeb.InventoryHTTP` maps every error.
  Interlock conflicts become `409` with a typed `code`, per-definition value
  failures become `422` carrying `fields["values.<definitionId>"]`, and
  nothing is allowed to surface as a server error.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryItemsJSON]

  @doc """
  GET /inventory/items
  """
  def index(conn, params) do
    with {:ok, page} <- Inventory.list_operator_items(params) do
      conn |> put_view(@view) |> render(:index, page: page)
    end
  end

  @doc """
  POST /inventory/items
  """
  def create(conn, params) do
    params
    |> Inventory.create_operator_item(actor_id(conn))
    |> render_item(conn, :created)
  end

  @doc """
  GET /inventory/items/:slugOrId
  """
  def show(conn, %{"slugOrId" => slug_or_id}) do
    slug_or_id |> Inventory.resolve_operator_item() |> render_item(conn)
  end

  @doc """
  PATCH /inventory/items/:slugOrId
  """
  def update(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.update_operator_item(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  DELETE /inventory/items/:slugOrId
  """
  def delete(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id |> Inventory.delete_operator_item(params) |> render_item(conn)
  end

  @doc """
  POST /inventory/items/:slugOrId/category
  """
  def change_category(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.change_operator_item_category(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  POST /inventory/items/:slugOrId/move
  """
  def move(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.move_operator_item(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  GET /inventory/items/:slugOrId/maintenance
  """
  def list_maintenance(conn, %{"slugOrId" => slug_or_id}) do
    with {:ok, _item} <- slug_or_id |> Inventory.resolve_operator_item() |> item_error() do
      periods = Inventory.list_operator_item_maintenance_periods(slug_or_id)
      conn |> put_view(@view) |> render(:maintenance, periods: periods)
    end
  end

  @doc """
  POST /inventory/items/:slugOrId/maintenance/start
  """
  def start_maintenance(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.start_operator_item_maintenance(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  POST /inventory/items/:slugOrId/maintenance/end
  """
  def end_maintenance(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.end_operator_item_maintenance(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  POST /inventory/items/:slugOrId/archive
  """
  def archive(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.archive_operator_item(params, actor_id(conn))
    |> render_item(conn)
  end

  @doc """
  POST /inventory/items/:slugOrId/restore
  """
  def restore(conn, %{"slugOrId" => slug_or_id}) do
    slug_or_id |> Inventory.restore_operator_item(actor_id(conn)) |> render_item(conn)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp render_item(result, conn, success_status \\ :ok)

  defp render_item({:ok, item}, conn, success_status) do
    conn
    |> put_status(success_status)
    |> put_view(@view)
    |> render(:show, item: item)
  end

  # Per-definition failures travel as `fields["values.<definitionId>"]`.
  defp render_item({:error, :invalid_values, value_errors}, _conn, _status),
    do: {:error, :invalid_values, DhcWeb.InventoryHTTP.value_fields(value_errors)}

  defp render_item(error, _conn, _status), do: item_error(error)

  # This slice's `:not_found` is always the addressed Item.
  defp item_error({:error, :not_found}), do: {:error, :item_not_found}
  defp item_error(result), do: result

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
