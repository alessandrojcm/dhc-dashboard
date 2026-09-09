defmodule DhcWeb.InventoryStructureController do
  @moduledoc """
  Operator structure viewers for Property Definitions and Options — ALE-283c.

    * GET    /inventory/categories/:categoryId/definitions — list, any member.
    * POST   /inventory/categories/:categoryId/definitions — create, write roles.
    * GET    /inventory/definitions/:id                    — show, any member.
    * PATCH  /inventory/definitions/:id                    — update, write roles.
    * POST   /inventory/definitions/:id/retire             — retire, write roles.
    * GET    /inventory/definitions/:definitionId/options  — list, any member.
    * POST   /inventory/definitions/:definitionId/options  — create, write roles.
    * PATCH  /inventory/options/:id                        — update, write roles.
    * POST   /inventory/options/:id/retire                 — retire, write roles.

  RBAC is enforced by the `:authenticated_api` (reads) and
  `:inventory_admin_api` (writes) pipelines. The controller maps
  `Dhc.Inventory` result tuples to HTTP status codes and delegates
  rendering to `DhcWeb.InventoryStructureJSON`.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @doc """
  GET /inventory/categories/{categoryId}/definitions
  """
  def index(conn, %{"categoryId" => category_id}) do
    definitions = Inventory.list_definitions(category_id)

    conn
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:index, definitions: definitions)
  end

  @doc """
  POST /inventory/categories/{categoryId}/definitions
  """
  def create(conn, %{"categoryId" => category_id} = params) do
    case Inventory.create_definition(category_id, params) do
      {:ok, definition} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:show, definition: definition)

      {:error, :not_found} ->
        not_found(conn, "Category not found")

      {:error, :conflict, _changeset} ->
        conflict(conn, "A definition with that label already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  GET /inventory/definitions/{id}
  """
  def show(conn, %{"id" => id}) do
    case Inventory.get_definition(id) do
      {:ok, definition} ->
        conn
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:show, definition: definition)

      {:error, :not_found} ->
        not_found(conn, "Definition not found")
    end
  end

  @doc """
  PATCH /inventory/definitions/{id}
  """
  def update(conn, %{"id" => id} = params) do
    case Inventory.update_definition(id, params) do
      {:ok, definition} ->
        conn
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:show, definition: definition)

      {:error, :not_found} ->
        not_found(conn, "Definition not found")

      {:error, :type_immutable} ->
        unprocessable_code(
          conn,
          "valueType cannot change once the definition is used",
          "type_immutable"
        )

      {:error, :required_blocked, %{item_ids: item_ids}} ->
        unprocessable_code(
          conn,
          "required cannot be set until every active item has a valid value",
          "required_blocked",
          %{itemIds: item_ids}
        )

      {:error, :conflict, _changeset} ->
        conflict(conn, "A definition with that label already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  POST /inventory/definitions/{id}/retire
  """
  def retire(conn, %{"id" => id}) do
    case Inventory.retire_definition(id) do
      {:ok, definition} ->
        conn
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:show, definition: definition)

      {:error, :not_found} ->
        not_found(conn, "Definition not found")

      {:error, :still_referenced, %{active_value_count: count}} ->
        conflict_code(
          conn,
          "definition is still referenced by active item values",
          "still_referenced",
          %{activeValueCount: count}
        )
    end
  end

  @doc """
  GET /inventory/definitions/{definitionId}/options
  """
  def index_options(conn, %{"definitionId" => definition_id}) do
    options = Inventory.list_options(definition_id)

    conn
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:options, options: options)
  end

  @doc """
  POST /inventory/definitions/{definitionId}/options
  """
  def create_option(conn, %{"definitionId" => definition_id} = params) do
    case Inventory.create_option(definition_id, params) do
      {:ok, option} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:option, option: option)

      {:error, :not_found} ->
        not_found(conn, "Definition not found")

      {:error, :not_single_select} ->
        unprocessable_code(
          conn,
          "options are only allowed on single_select definitions",
          "not_single_select"
        )

      {:error, :conflict, _changeset} ->
        conflict(conn, "An option with that label already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  PATCH /inventory/options/{id}
  """
  def update_option(conn, %{"id" => id} = params) do
    case Inventory.update_option(id, params) do
      {:ok, option} ->
        conn
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:option, option: option)

      {:error, :not_found} ->
        not_found(conn, "Option not found")

      {:error, :conflict, _changeset} ->
        conflict(conn, "An option with that label already exists")

      {:error, changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  POST /inventory/options/{id}/retire
  """
  def retire_option(conn, %{"id" => id}) do
    case Inventory.retire_option(id) do
      {:ok, option} ->
        conn
        |> put_view(json: DhcWeb.InventoryStructureJSON)
        |> render(:option, option: option)

      {:error, :not_found} ->
        not_found(conn, "Option not found")

      {:error, :still_referenced, %{active_value_count: count}} ->
        conflict_code(
          conn,
          "option is still referenced by active item values",
          "still_referenced",
          %{activeValueCount: count}
        )
    end
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:error, detail: detail)
  end

  defp conflict(conn, detail) do
    conn
    |> put_status(:conflict)
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:error, detail: detail)
  end

  defp conflict_code(conn, detail, code, extra) do
    conn
    |> put_status(:conflict)
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:error, Map.merge(%{detail: detail, code: code}, extra))
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> render_error_detail()

    unprocessable_detail(conn, detail)
  end

  defp unprocessable_code(conn, detail, code, extra \\ %{}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:error, Map.merge(%{detail: detail, code: code}, extra))
  end

  defp unprocessable_detail(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.InventoryStructureJSON)
    |> render(:error, detail: detail)
  end

  defp render_error_detail(errors) when errors == %{}, do: "Invalid definition payload"

  defp render_error_detail(errors) do
    Enum.map_join(errors, "; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end
end
