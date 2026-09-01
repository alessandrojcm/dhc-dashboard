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
  alias DhcWeb.ConditionalRequests

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
    actor_id = conn.assigns.current_session.principal.id

    case Inventory.create_item(params, actor_id) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> ConditionalRequests.put_etag(item.lock_version)
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
        precondition = ConditionalRequests.evaluate(conn, item.lock_version)

        case ConditionalRequests.maybe_send_not_modified(conn, precondition) do
          %Plug.Conn{} = conn_304 ->
            conn_304

          {:ok, nil} ->
            item_response(conn, item)

          # If-Match on a GET: RFC 9110 §13.1.1 — match serves normally, a
          # stale witness is a 412 (AEP-154: never silently ignored).
          {:ok, if_match} ->
            enforce_get_if_match(conn, item, if_match)

          {:error, reason} ->
            bad_request(conn, ConditionalRequests.error_detail(reason))
        end

      {:error, :not_found} ->
        not_found(conn, "Item not found")
    end
  end

  @doc """
  PATCH /inventory/items/{id}
  """
  def update(conn, %{"id" => id} = params) do
    actor_id = conn.assigns.current_session.principal.id

    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        apply_update(conn, id, params, actor_id, opts)

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  @doc """
  DELETE /inventory/items/{id}
  """
  def delete(conn, %{"id" => id}) do
    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        apply_delete(conn, id, opts)

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
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
    actor_id = conn.assigns.current_session.principal.id

    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        case Inventory.move_item(id, params, actor_id, opts) do
          {:ok, item} -> item_response(conn, item)
          {:error, :not_found} -> not_found(conn, "Item not found")
          {:error, {:version_precondition_failed, current}} -> precondition_failed(conn, current)
          {:error, :invalid_container} -> unprocessable(conn, "container_id unknown container")
          {:error, changeset} -> unprocessable(conn, changeset)
        end

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  @doc """
  POST /inventory/items/{id}/maintenance — ALE-108 dedicated maintenance command.
  """
  def maintenance(conn, %{"id" => id} = params) do
    actor_id = conn.assigns.current_session.principal.id

    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        case Inventory.set_item_maintenance(id, params, actor_id, opts) do
          {:ok, item} -> item_response(conn, item)
          {:error, :not_found} -> not_found(conn, "Item not found")
          {:error, {:version_precondition_failed, current}} -> precondition_failed(conn, current)
          {:error, changeset} -> unprocessable(conn, changeset)
        end

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  # ── Conditional-request helpers (ALE-266, ADR 0023) ──────────────────

  defp enforce_get_if_match(conn, item, if_match) do
    case ConditionalRequests.enforce_if_match(if_match, item.lock_version) do
      :ok -> item_response(conn, item)
      {:precondition_failed} -> precondition_failed(conn, item)
    end
  end

  defp apply_update(conn, id, params, actor_id, opts) do
    case Inventory.update_item(id, params, actor_id, opts) do
      {:ok, item} ->
        item_response(conn, item)

      {:error, :not_found} ->
        not_found(conn, "Item not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  defp apply_delete(conn, id, opts) do
    case Inventory.delete_item(id, opts) do
      {:ok, _item} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Item not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)
    end
  end

  defp item_response(conn, item) do
    conn
    |> ConditionalRequests.put_etag(item.lock_version)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:item, item: item)
  end

  # 412 Precondition Failed — ADR 0023: the body carries the *current*
  # server entity so the client can refetch/reconcile, alongside the error
  # detail, reusing the response envelope.
  defp precondition_failed(conn, current_item) do
    conn
    |> ConditionalRequests.put_etag(current_item.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.InventoryItemsJSON)
    |> render(:precondition_failed, item: current_item)
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
