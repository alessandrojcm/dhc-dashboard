defmodule DhcWeb.InventoryContainersController do
  @moduledoc """
  Inventory Container management endpoints — ALE-106.

  Mirrors the ALE-104 Inventory REST contract for the container slice:

    * GET    /inventory/containers       — list (flat, with itemCount +
      parentContainer summary), any authenticated member.
    * POST   /inventory/containers       — create, write roles.
    * GET    /inventory/containers/:id   — detail (parent + childContainers +
      items with category summary), any authenticated member.
    * PATCH  /inventory/containers/:id   — update, write roles.
    * POST   /inventory/containers/:id/move    — dedicated move, write roles.
    * POST   /inventory/containers/:id/archive — archive, write roles.
    * POST   /inventory/containers/:id/restore — restore, write roles.
    * DELETE /inventory/containers/:id   — delete (204), write roles.

  RBAC is enforced by the `:inventory_manage` (writes) and
  `:authenticated_api` (reads) pipelines in the router, mirroring the existing
  SvelteKit `INVENTORY_ROLES` (`quartermaster`, `president`, `admin`).

  The controller does no business logic; it derives `created_by` from
  `conn.assigns.current_user.sub` on create, renders successes through
  `DhcWeb.InventoryContainersJSON`, and leaves errors to
  `DhcWeb.InventoryHTTP`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryContainersJSON]

  @doc """
  GET /inventory/containers
  """
  def index(conn, _params) do
    conn |> put_view(@view) |> render(:index, containers: Inventory.list_containers())
  end

  @doc """
  GET /inventory/containers/{id}
  """
  def show(conn, %{"id" => id}) do
    with {:ok, container} <- id |> Inventory.get_container() |> container_result() do
      conn |> put_view(@view) |> render(:show, container: container)
    end
  end

  @doc """
  POST /inventory/containers
  """
  def create(conn, params) do
    # `created_by` is NOT NULL on the `containers` table and now
    # references the Phoenix session principal.
    actor_id = conn.assigns.current_session.principal.id

    params |> Inventory.create_container(actor_id) |> render_item(conn, :created)
  end

  @doc """
  PATCH /inventory/containers/{id}
  """
  def update(conn, %{"id" => id} = params) do
    id |> Inventory.update_container(params) |> render_item(conn)
  end

  @doc """
  POST /inventory/containers/{id}/move
  """
  def move(conn, %{"id" => id} = params) do
    parent_id = Map.get(params, "parentContainerId") || Map.get(params, "parent_container_id")

    id |> Inventory.move_container(parent_id) |> render_item(conn)
  end

  @doc """
  POST /inventory/containers/{id}/archive
  """
  def archive(conn, %{"id" => id}) do
    id |> Inventory.archive_container() |> render_item(conn)
  end

  @doc """
  POST /inventory/containers/{id}/restore
  """
  def restore(conn, %{"id" => id}) do
    id |> Inventory.restore_container() |> render_item(conn)
  end

  @doc """
  DELETE /inventory/containers/{id}
  """
  def delete(conn, %{"id" => id}) do
    with {:ok, _container} <- id |> Inventory.delete_container() |> container_result() do
      send_resp(conn, :no_content, "")
    end
  end

  defp render_item(result, conn, status \\ :ok) do
    with {:ok, container} <- container_result(result) do
      conn |> put_status(status) |> put_view(@view) |> render(:item, container: container)
    end
  end

  defp container_result({:error, :not_found}), do: {:error, :container_not_found}
  defp container_result({:error, :still_referenced}), do: {:error, :container_still_referenced}
  defp container_result(result), do: result
end
