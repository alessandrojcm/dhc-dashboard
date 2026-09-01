defmodule DhcWeb.InventoryCategoriesController do
  @moduledoc """
  Equipment Category (Inventory Category) management endpoints — ALE-105.

  Mirrors the ALE-104 Inventory REST contract for the category slice:

    * GET    /inventory/categories       — list, any authenticated member.
    * GET    /inventory/categories/:id   — show, any authenticated member.
    * POST   /inventory/categories       — create, write roles.
    * PATCH  /inventory/categories/:id   — update, write roles.
    * DELETE /inventory/categories/:id   — delete (204), write roles.

  RBAC is enforced by the `:inventory_admin_api` (writes) and
  `:authenticated_api` (reads) pipelines in the router, mirroring the existing
  SvelteKit `INVENTORY_ROLES` (`quartermaster`, `president`, `admin`).

  The controller does no business logic; it maps context result tuples to HTTP
  status codes and delegates rendering to `DhcWeb.InventoryCategoriesJSON`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory
  alias DhcWeb.ConditionalRequests

  @doc """
  GET /inventory/categories
  """
  def index(conn, _params) do
    categories = Inventory.list_categories()

    conn
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:index, categories: categories)
  end

  @doc """
  GET /inventory/categories/{id}
  """
  def show(conn, %{"id" => id}) do
    case Inventory.get_category(id) do
      {:ok, category} ->
        precondition = ConditionalRequests.evaluate(conn, category.lock_version)

        case ConditionalRequests.maybe_send_not_modified(conn, precondition) do
          %Plug.Conn{} = conn_304 ->
            conn_304

          {:ok, nil} ->
            category_response(conn, category)

          # If-Match on a GET: RFC 9110 §13.1.1 — match serves normally, a
          # stale witness is a 412 (AEP-154: never silently ignored).
          {:ok, if_match} ->
            enforce_get_if_match(conn, category, if_match)

          {:error, reason} ->
            bad_request(conn, ConditionalRequests.error_detail(reason))
        end

      {:error, :not_found} ->
        not_found(conn, "Category not found")
    end
  end

  @doc """
  POST /inventory/categories
  """
  def create(conn, params) do
    case Inventory.create_category(params) do
      {:ok, category} ->
        conn
        |> put_status(:created)
        |> ConditionalRequests.put_etag(category.lock_version)
        |> put_view(json: DhcWeb.InventoryCategoriesJSON)
        |> render(:show, category: category)

      {:error, :conflict, _changeset} ->
        conflict(conn, "A category with that name already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  PATCH /inventory/categories/{id}
  """
  def update(conn, %{"id" => id} = params) do
    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        apply_update(conn, id, params, opts)

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  @doc """
  DELETE /inventory/categories/{id}
  """
  def delete(conn, %{"id" => id}) do
    case ConditionalRequests.write_options(conn) do
      {:ok, opts} ->
        apply_delete(conn, id, opts)

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  # ── Conditional-request helpers (ALE-267, ADR 0023) ──────────────────

  defp enforce_get_if_match(conn, category, if_match) do
    case ConditionalRequests.enforce_if_match(if_match, category.lock_version) do
      :ok -> category_response(conn, category)
      {:precondition_failed} -> precondition_failed(conn, category)
    end
  end

  defp apply_update(conn, id, params, opts) do
    case Inventory.update_category(id, params, opts) do
      {:ok, category} ->
        category_response(conn, category)

      {:error, :not_found} ->
        not_found(conn, "Category not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

      {:error, :conflict, _changeset} ->
        conflict(conn, "A category with that name already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  defp apply_delete(conn, id, opts) do
    case Inventory.delete_category(id, opts) do
      {:ok, _category} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Category not found")

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

      {:error, :still_referenced} ->
        # 409, matching the ALE-104 contract.
        conflict(conn, "Category is still referenced by inventory items")
    end
  end

  defp category_response(conn, category) do
    conn
    |> ConditionalRequests.put_etag(category.lock_version)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:show, category: category)
  end

  # 412 Precondition Failed — ADR 0023: the body carries the *current*
  # server entity so the client can refetch/reconcile, alongside the error
  # detail, reusing the response envelope.
  defp precondition_failed(conn, current_category) do
    conn
    |> ConditionalRequests.put_etag(current_category.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:precondition_failed, category: current_category)
  end

  # ── Error helpers ─────────────────────────────────────────────────────

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:error, detail: detail)
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:error, detail: detail)
  end

  defp conflict(conn, detail) do
    conn
    |> put_status(:conflict)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:error, detail: detail)
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> render_error_detail()

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.InventoryCategoriesJSON)
    |> render(:error, detail: detail)
  end

  # traverse_errors returns a nested map of field → [messages]. Flatten to a
  # human-readable string (matches the project's flat `errors.detail` shape).
  defp render_error_detail(errors) when errors == %{}, do: "Invalid category payload"

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
