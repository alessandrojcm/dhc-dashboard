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
    * DELETE /inventory/containers/:id   — delete (204), write roles.

  RBAC is enforced by the `:inventory_admin_api` (writes) and
  `:authenticated_api` (reads) pipelines in the router, mirroring the existing
  SvelteKit `INVENTORY_ROLES` (`quartermaster`, `president`, `admin`).

  The controller does no business logic; it derives `created_by` from
  `conn.assigns.current_user.sub` on create, maps `Dhc.Inventory` result
  tuples to HTTP status codes, and delegates rendering to
  `DhcWeb.InventoryContainersJSON`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @doc """
  GET /inventory/containers
  """
  def index(conn, _params) do
    containers = Inventory.list_containers()

    conn
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:index, containers: containers)
  end

  @doc """
  GET /inventory/containers/{id}
  """
  def show(conn, %{"id" => id}) do
    case Inventory.get_container(id) do
      {:ok, container} ->
        conn
        |> put_view(json: DhcWeb.InventoryContainersJSON)
        |> render(:show, container: container)

      {:error, :not_found} ->
        not_found(conn, "Container not found")
    end
  end

  @doc """
  POST /inventory/containers
  """
  def create(conn, params) do
    # `created_by` is NOT NULL on the `containers` table and references
    # `auth.users`; the authenticated pipeline guarantees `current_user`.
    actor_id = conn.assigns.current_user.sub

    case Inventory.create_container(params, actor_id) do
      {:ok, container} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.InventoryContainersJSON)
        |> render(:item, container: container)

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  PATCH /inventory/containers/{id}
  """
  def update(conn, %{"id" => id} = params) do
    case Inventory.update_container(id, params) do
      {:ok, container} ->
        conn
        |> put_view(json: DhcWeb.InventoryContainersJSON)
        |> render(:item, container: container)

      {:error, :not_found} ->
        not_found(conn, "Container not found")

      {:error, :circular_parent} ->
        unprocessable_detail(conn, "parentContainerId would create a cycle")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  DELETE /inventory/containers/{id}
  """
  def delete(conn, %{"id" => id}) do
    case Inventory.delete_container(id) do
      {:ok, _container} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Container not found")

      {:error, :still_referenced} ->
        # 409, matching the ALE-104 contract.
        conflict(conn, "Container still contains inventory items")
    end
  end

  # ── Error helpers ─────────────────────────────────────────────────────

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:error, detail: detail)
  end

  defp conflict(conn, detail) do
    conn
    |> put_status(:conflict)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:error, detail: detail)
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> render_error_detail()

    unprocessable_detail(conn, detail)
  end

  defp unprocessable_detail(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:error, detail: detail)
  end

  # traverse_errors returns a nested map of field → [messages]. Flatten to a
  # human-readable string (matches the project's flat `errors.detail` shape).
  defp render_error_detail(errors) when errors == %{}, do: "Invalid container payload"

  defp render_error_detail(errors) do
    Enum.map_join(errors, "; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end

  defp send_delete(conn) do
    conn
    |> put_status(:no_content)
    |> send_resp(:no_content, "")
  end
end
