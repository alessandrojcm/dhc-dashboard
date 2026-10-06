defmodule DhcWeb.InventoryStructureController do
  @moduledoc """
  Operator structure viewers for Property Definitions and Options — ALE-283c.

    * GET    /inventory/categories/:categoryId/definitions — list, any member.
    * POST   /inventory/categories/:categoryId/definitions — create, inventory operators.
    * GET    /inventory/definitions/:id                    — show, any member.
    * PATCH  /inventory/definitions/:id                    — update, inventory operators.
    * POST   /inventory/definitions/:id/retire             — retire, inventory operators.
    * GET    /inventory/definitions/:definitionId/options  — list, any member.
    * POST   /inventory/definitions/:definitionId/options  — create, inventory operators.
    * PATCH  /inventory/options/:id                        — update, inventory operators.
    * POST   /inventory/options/:id/retire                 — retire, inventory operators.

  RBAC is enforced by the `:authenticated_api` (reads) and
  `:inventory_manage` (writes) pipelines. The controller renders
  successes through `DhcWeb.InventoryStructureJSON` and leaves errors to
  `DhcWeb.InventoryHTTP` (`required_blocked` lists the blocking items as
  `fields["items.<itemId>"]`).
  """

  use DhcWeb, :controller

  alias Dhc.Inventory
  alias DhcWeb.InventoryHTTP

  action_fallback InventoryHTTP

  @view [json: DhcWeb.InventoryStructureJSON]

  @doc """
  GET /inventory/categories/{categoryId}/definitions
  """
  def index(conn, %{"categoryId" => category_id}) do
    conn
    |> put_view(@view)
    |> render(:index, definitions: Inventory.list_definitions(category_id))
  end

  @doc """
  POST /inventory/categories/{categoryId}/definitions
  """
  def create(conn, %{"categoryId" => category_id} = params) do
    case Inventory.create_definition(category_id, params) do
      {:error, :not_found} -> {:error, :category_not_found}
      result -> render_definition(result, conn, :created)
    end
  end

  @doc """
  GET /inventory/definitions/{id}
  """
  def show(conn, %{"id" => id}) do
    id |> Inventory.get_definition() |> render_definition(conn)
  end

  @doc """
  PATCH /inventory/definitions/{id}
  """
  def update(conn, %{"id" => id} = params) do
    case Inventory.update_definition(id, params) do
      {:error, :required_blocked, %{item_ids: item_ids}} ->
        {:error, :required_blocked, InventoryHTTP.blocking_item_fields(item_ids)}

      result ->
        render_definition(result, conn)
    end
  end

  @doc """
  POST /inventory/definitions/{id}/retire
  """
  def retire(conn, %{"id" => id}) do
    case Inventory.retire_definition(id) do
      {:error, :still_referenced, _counts} -> {:error, :definition_still_referenced}
      result -> render_definition(result, conn)
    end
  end

  @doc """
  GET /inventory/definitions/{definitionId}/options
  """
  def index_options(conn, %{"definitionId" => definition_id}) do
    conn |> put_view(@view) |> render(:options, options: Inventory.list_options(definition_id))
  end

  @doc """
  POST /inventory/definitions/{definitionId}/options
  """
  def create_option(conn, %{"definitionId" => definition_id} = params) do
    case Inventory.create_option(definition_id, params) do
      {:error, :not_found} -> {:error, :definition_not_found}
      result -> render_option(result, conn, :created)
    end
  end

  @doc """
  PATCH /inventory/options/{id}
  """
  def update_option(conn, %{"id" => id} = params) do
    id |> Inventory.update_option(params) |> render_option(conn)
  end

  @doc """
  POST /inventory/options/{id}/retire
  """
  def retire_option(conn, %{"id" => id}) do
    case Inventory.retire_option(id) do
      {:error, :still_referenced, _counts} -> {:error, :option_still_referenced}
      result -> render_option(result, conn)
    end
  end

  defp render_definition(result, conn, status \\ :ok)

  defp render_definition({:ok, definition}, conn, status) do
    conn |> put_status(status) |> put_view(@view) |> render(:show, definition: definition)
  end

  defp render_definition({:error, :not_found}, _conn, _status),
    do: {:error, :definition_not_found}

  defp render_definition({:error, :conflict, _changeset}, _conn, _status),
    do: {:error, :definition_label_taken}

  defp render_definition(error, _conn, _status), do: error

  defp render_option(result, conn, status \\ :ok)

  defp render_option({:ok, option}, conn, status) do
    conn |> put_status(status) |> put_view(@view) |> render(:option, option: option)
  end

  defp render_option({:error, :not_found}, _conn, _status), do: {:error, :option_not_found}

  defp render_option({:error, :conflict, _changeset}, _conn, _status),
    do: {:error, :option_label_taken}

  defp render_option(error, _conn, _status), do: error
end
