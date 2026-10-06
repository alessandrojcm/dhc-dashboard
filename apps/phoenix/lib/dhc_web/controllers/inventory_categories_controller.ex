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

  The controller does no business logic; it renders successes through
  `DhcWeb.InventoryCategoriesJSON` and leaves errors to `DhcWeb.InventoryHTTP`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryCategoriesJSON]

  @doc """
  GET /inventory/categories
  """
  def index(conn, _params) do
    conn |> put_view(@view) |> render(:index, categories: Inventory.list_categories())
  end

  @doc """
  GET /inventory/categories/{id}
  """
  def show(conn, %{"id" => id}) do
    id |> Inventory.get_category() |> render_category(conn)
  end

  @doc """
  POST /inventory/categories
  """
  def create(conn, params) do
    params |> Inventory.create_category() |> render_category(conn, :created)
  end

  @doc """
  PATCH /inventory/categories/{id}
  """
  def update(conn, %{"id" => id} = params) do
    id |> Inventory.update_category(params) |> render_category(conn)
  end

  @doc """
  DELETE /inventory/categories/{id}
  """
  def delete(conn, %{"id" => id}) do
    case Inventory.delete_category(id) do
      {:ok, _category} -> send_resp(conn, :no_content, "")
      error -> category_error(error)
    end
  end

  defp render_category(result, conn, status \\ :ok)

  defp render_category({:ok, category}, conn, status) do
    conn |> put_status(status) |> put_view(@view) |> render(:show, category: category)
  end

  defp render_category(error, _conn, _status), do: category_error(error)

  defp category_error({:error, :not_found}), do: {:error, :category_not_found}
  defp category_error({:error, :conflict, _changeset}), do: {:error, :category_name_taken}
  # 409, matching the ALE-104 contract.
  defp category_error({:error, :still_referenced}), do: {:error, :category_still_referenced}
  defp category_error(error), do: error
end
