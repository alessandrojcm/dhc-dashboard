defmodule DhcWeb.InventoryItemsController do
  @moduledoc """
  Inventory Item management endpoints — ALE-107.

  Mirrors the ALE-104 Inventory REST contract for the item slice:

    * GET    /inventory/items          — list (cursor-paginated, filtered,
      with container/category summaries), any authenticated member.
    * POST   /inventory/items          — create, write roles.
    * GET    /inventory/items/:id       — detail (container/category summaries),
      any authenticated member.
    * PATCH  /inventory/items/:id       — update, write roles.
    * DELETE /inventory/items/:id       — delete (204), write roles.
    * GET    /inventory/items/:id/history — item history (newest first), any
      authenticated member.

  RBAC is enforced by the `:inventory_admin_api` (writes) and
  `:authenticated_api` (reads) pipelines in the router, mirroring the existing
  SvelteKit `INVENTORY_ROLES` (`quartermaster`, `president`, `admin`).

  The controller does no business logic; it derives `created_by`/`updated_by`
  from `conn.assigns.current_user.sub` on write, maps `Dhc.Inventory` result
  tuples to HTTP status codes, and delegates rendering to
  `DhcWeb.InventoryItemsJSON`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @doc """
  GET /inventory/items
  """
  def index(conn, params) do
    case Inventory.list_items(params) do
      {:ok, %{items: items, limit: limit, next_cursor: next_cursor}} ->
        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:index, items: items, limit: limit, next_cursor: next_cursor)

      {:error, :invalid_limit} ->
        bad_request(conn, "limit must be one of 10, 25, 50, 100")

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or stale cursor")
    end
  end

  @doc """
  POST /inventory/items
  """
  def create(conn, params) do
    actor_id = conn.assigns.current_user.sub

    case Inventory.create_item(params, actor_id) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:item, item: item)

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  GET /inventory/items/{id}
  """
  def show(conn, %{"id" => id}) do
    case Inventory.get_item(id) do
      {:ok, item} ->
        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:item, item: item)

      {:error, :not_found} ->
        not_found(conn, "Item not found")
    end
  end

  @doc """
  PATCH /inventory/items/{id}
  """
  def update(conn, %{"id" => id} = params) do
    actor_id = conn.assigns.current_user.sub

    case Inventory.update_item(id, params, actor_id) do
      {:ok, item} ->
        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:item, item: item)

      {:error, :not_found} ->
        not_found(conn, "Item not found")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  DELETE /inventory/items/{id}
  """
  def delete(conn, %{"id" => id}) do
    case Inventory.delete_item(id) do
      {:ok, _item} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Item not found")
    end
  end

  @doc """
  GET /inventory/items/{id}/history
  """
  def history(conn, %{"id" => id} = params) do
    case Inventory.list_item_history(id, params) do
      {:ok, history} ->
        limit = history_limit(params)

        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:history, history: history, limit: limit)

      {:error, :not_found} ->
        not_found(conn, "Item not found")
    end
  end

  @doc """
  POST /inventory/items/{id}/move — ALE-108 dedicated move command.
  """
  def move(conn, %{"id" => id} = params) do
    actor_id = conn.assigns.current_user.sub

    case Inventory.move_item(id, params, actor_id) do
      {:ok, item} ->
        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:item, item: item)

      {:error, :not_found} ->
        not_found(conn, "Item not found")

      {:error, :invalid_container} ->
        unprocessable(conn, "container_id unknown container")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  POST /inventory/items/{id}/maintenance — ALE-108 dedicated maintenance command.
  """
  def maintenance(conn, %{"id" => id} = params) do
    actor_id = conn.assigns.current_user.sub

    case Inventory.set_item_maintenance(id, params, actor_id) do
      {:ok, item} ->
        conn
        |> put_view(json: DhcWeb.InventoryItemsJSON)
        |> render(:item, item: item)

      {:error, :not_found} ->
        not_found(conn, "Item not found")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  # ── Error helpers ─────────────────────────────────────────────────────

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:error, detail: detail)
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:error, detail: detail)
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> render_error_detail()

    unprocessable_detail(conn, detail)
  end

  defp unprocessable(conn, detail) when is_binary(detail) do
    unprocessable_detail(conn, detail)
  end

  defp unprocessable_detail(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:error, detail: detail)
  end

  # traverse_errors returns a nested map of field → [messages]. Flatten to a
  # human-readable string (matches the project's flat `errors.detail` shape).
  defp render_error_detail(errors) when errors == %{}, do: "Invalid item payload"

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

  defp history_limit(%{"limit" => limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> n
      _ -> 20
    end
  end

  defp history_limit(%{"limit" => limit}) when is_integer(limit), do: limit
  defp history_limit(_), do: 20
end
