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
  alias DhcWeb.ConditionalRequests

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
        precondition = ConditionalRequests.evaluate(conn, container.lock_version)

        case ConditionalRequests.maybe_send_not_modified(conn, precondition) do
          %Plug.Conn{} = conn_304 ->
            conn_304

          {:ok, nil} ->
            container_response(conn, container, :show)

          # If-Match on a GET: RFC 9110 §13.1.1 — match serves normally, a
          # stale witness is a 412 (AEP-154: never silently ignored).
          {:ok, if_match} ->
            enforce_get_if_match(conn, container, if_match)

          {:error, reason} ->
            bad_request(conn, ConditionalRequests.error_detail(reason))
        end

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
    actor_id = conn.assigns.current_session.principal.id

    case Inventory.create_container(params, actor_id) do
      {:ok, container} ->
        conn
        |> put_status(:created)
        |> ConditionalRequests.put_etag(container.lock_version)
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
    case fetch_if_match(conn) do
      {:ok, nil} ->
        apply_update(conn, id, params, [])

      {:ok, if_match} ->
        apply_update(conn, id, params, expected_lock_version: expected_version(if_match))

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  @doc """
  DELETE /inventory/containers/{id}
  """
  def delete(conn, %{"id" => id}) do
    case fetch_if_match(conn) do
      {:ok, nil} ->
        apply_delete(conn, id, [])

      {:ok, if_match} ->
        apply_delete(conn, id, expected_lock_version: expected_version(if_match))

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  # ── Conditional-request helpers (ALE-267, ADR 0023) ──────────────────

  defp enforce_get_if_match(conn, container, if_match) do
    case ConditionalRequests.enforce_if_match(if_match, container.lock_version) do
      :ok -> container_response(conn, container, :show)
      {:precondition_failed} -> precondition_failed(conn, container)
    end
  end

  defp fetch_if_match(conn), do: ConditionalRequests.parse_if_match(conn)

  defp expected_version({:version, version}), do: version
  defp expected_version({:any_existing, :*}), do: :*

  defp apply_update(conn, id, params, opts) do
    case Inventory.update_container(id, params, opts) do
      {:ok, container} ->
        container_response(conn, container, :item)

      {:error, :not_found} ->
        not_found(conn, "Container not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

      {:error, :circular_parent} ->
        unprocessable_detail(conn, "parentContainerId would create a cycle")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  defp apply_delete(conn, id, opts) do
    case Inventory.delete_container(id, opts) do
      {:ok, _container} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Container not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

      {:error, :still_referenced} ->
        # 409, matching the ALE-104 contract.
        conflict(conn, "Container still contains inventory items")
    end
  end

  defp container_response(conn, container, template) do
    conn
    |> ConditionalRequests.put_etag(container.lock_version)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(template, container: container)
  end

  # 412 Precondition Failed — ADR 0023: the body carries the *current*
  # server entity so the client can refetch/reconcile, alongside the error
  # detail, reusing the response envelope.
  defp precondition_failed(conn, current_container) do
    conn
    |> ConditionalRequests.put_etag(current_container.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:precondition_failed, container: current_container)
  end

  # ── Error helpers ─────────────────────────────────────────────────────

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> put_view(json: DhcWeb.InventoryContainersJSON)
    |> render(:error, detail: detail)
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
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
