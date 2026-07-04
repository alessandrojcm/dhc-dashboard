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
        conn
        |> put_view(json: DhcWeb.InventoryCategoriesJSON)
        |> render(:show, category: category)

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
    case Inventory.update_category(id, params) do
      {:ok, category} ->
        conn
        |> put_view(json: DhcWeb.InventoryCategoriesJSON)
        |> render(:show, category: category)

      {:error, :not_found} ->
        not_found(conn, "Category not found")

      {:error, :conflict, _changeset} ->
        conflict(conn, "A category with that name already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  DELETE /inventory/categories/{id}
  """
  def delete(conn, %{"id" => id}) do
    case Inventory.delete_category(id) do
      {:ok, _category} ->
        send_delete(conn)

      {:error, :not_found} ->
        not_found(conn, "Category not found")

      {:error, :still_referenced} ->
        # 409, matching the ALE-104 contract.
        conflict(conn, "Category is still referenced by inventory items")
    end
  end

  # ── Error helpers ─────────────────────────────────────────────────────

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
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
