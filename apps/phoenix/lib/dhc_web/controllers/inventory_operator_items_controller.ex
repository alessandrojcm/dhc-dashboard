defmodule DhcWeb.InventoryOperatorItemsController do
  @moduledoc """
  Operator viewers and commands for target inventory Items — ALE-284c.

    * GET    /inventory/operator/items                                 — list, write roles.
    * POST   /inventory/operator/items                                 — create, write roles.
    * GET    /inventory/operator/items/:slugOrId                       — show, write roles.
    * PATCH  /inventory/operator/items/:slugOrId                       — generic edit, write roles.
    * DELETE /inventory/operator/items/:slugOrId                       — delete, write roles.
    * POST   /inventory/operator/items/:slugOrId/category              — reclassify, write roles.
    * POST   /inventory/operator/items/:slugOrId/move                  — move, write roles.
    * GET    /inventory/operator/items/:slugOrId/maintenance           — periods, write roles.
    * POST   /inventory/operator/items/:slugOrId/maintenance/start     — start, write roles.
    * POST   /inventory/operator/items/:slugOrId/maintenance/end       — end, write roles.
    * POST   /inventory/operator/items/:slugOrId/archive               — archive, write roles.
    * POST   /inventory/operator/items/:slugOrId/restore               — restore, write roles.

  Every command is its own action with its own request body, so the generic
  edit cannot express a move, a maintenance transition, an archive, or a
  loan change. Operator authority is equal for `quartermaster`,
  `president`, and `admin`, all enforced by the `:inventory_admin_api`
  pipeline.

  **Reads are operator-only too.** This viewer discloses the container
  location, operator notes, and maintenance facts, which spec ALE-280 story
  45 forbids exposing to members in ordinary browsing. The member-shaped
  catalog projection — label, slug, category, values, and a generic
  unavailability reason only — is ALE-285, not a role variant of this one.

  The controller only maps `Dhc.Inventory` result tuples onto status codes.
  Interlock conflicts become `409` with a typed `code`, per-definition value
  failures become `422` carrying `valueErrors`, and nothing is allowed to
  surface as a server error.

  These operations live under `/inventory/operator/items` only while the
  legacy `/inventory/items` routes still serve the current dashboard;
  ALE-289 moves them onto those URLs.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryOperatorItemsJSON]

  # Domain reasons that mean "an interlock refused this", not "you sent
  # something invalid" — they map to 409 with a machine-readable code.
  @conflict_codes %{
    archived: "The item is archived and therefore read-only",
    loan_active: "An approved or checked-out loan holds this item",
    maintenance_open: "The item already has an open maintenance period",
    no_open_maintenance: "The item has no open maintenance period",
    has_history: "The item has loan or maintenance history — archive it instead"
  }

  @validation_codes %{
    invalid_notes: "notes must be text",
    archived_category: "The category is archived",
    archived_container: "The container is archived",
    reason_required: "A maintenance reason is required",
    confirmation_required: "Deletion requires explicit confirmation"
  }

  @doc """
  GET /inventory/operator/items
  """
  def index(conn, params) do
    case Inventory.list_operator_items(params) do
      {:ok, page} ->
        conn |> put_view(@view) |> render(:index, page: page)

      {:error, reason} ->
        bad_request(conn, list_error_detail(reason))
    end
  end

  @doc """
  POST /inventory/operator/items
  """
  def create(conn, params) do
    params
    |> Inventory.create_operator_item(actor_id(conn))
    |> respond(conn, :created)
  end

  @doc """
  GET /inventory/operator/items/:slugOrId
  """
  def show(conn, %{"slugOrId" => slug_or_id}) do
    slug_or_id |> Inventory.resolve_operator_item() |> respond(conn)
  end

  @doc """
  PATCH /inventory/operator/items/:slugOrId
  """
  def update(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.update_operator_item(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  DELETE /inventory/operator/items/:slugOrId
  """
  def delete(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id |> Inventory.delete_operator_item(params) |> respond(conn)
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/category
  """
  def change_category(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.change_operator_item_category(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/move
  """
  def move(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.move_operator_item(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  GET /inventory/operator/items/:slugOrId/maintenance
  """
  def maintenance(conn, %{"slugOrId" => slug_or_id}) do
    case Inventory.resolve_operator_item(slug_or_id) do
      {:ok, _item} ->
        periods = Inventory.list_operator_item_maintenance_periods(slug_or_id)
        conn |> put_view(@view) |> render(:maintenance, periods: periods)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/maintenance/start
  """
  def start_maintenance(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.start_operator_item_maintenance(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/maintenance/end
  """
  def end_maintenance(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.end_operator_item_maintenance(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/archive
  """
  def archive(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.archive_operator_item(params, actor_id(conn))
    |> respond(conn)
  end

  @doc """
  POST /inventory/operator/items/:slugOrId/restore
  """
  def restore(conn, %{"slugOrId" => slug_or_id}) do
    slug_or_id |> Inventory.restore_operator_item(actor_id(conn)) |> respond(conn)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp respond(result, conn, success_status \\ :ok)

  defp respond({:ok, item}, conn, success_status) do
    conn
    |> put_status(success_status)
    |> put_view(@view)
    |> render(:show, item: item)
  end

  defp respond({:error, :not_found}, conn, _status), do: not_found(conn)

  defp respond({:error, :invalid_values, value_errors}, conn, _status) do
    render_error(conn, :unprocessable_entity, %{
      detail: "One or more property values are invalid",
      code: "invalid_values",
      valueErrors: value_errors
    })
  end

  defp respond({:error, reason}, conn, _status) when is_map_key(@conflict_codes, reason) do
    render_error(conn, :conflict, %{
      detail: Map.fetch!(@conflict_codes, reason),
      code: to_string(reason)
    })
  end

  defp respond({:error, reason}, conn, _status) when is_map_key(@validation_codes, reason) do
    render_error(conn, :unprocessable_entity, %{
      detail: Map.fetch!(@validation_codes, reason),
      code: to_string(reason)
    })
  end

  defp respond({:error, %Ecto.Changeset{} = changeset}, conn, _status) do
    render_error(conn, :unprocessable_entity, %{
      detail: changeset_detail(changeset),
      code: "invalid_values"
    })
  end

  defp list_error_detail(:invalid_limit), do: "limit must be one of 10, 25, 50, 100"
  defp list_error_detail(:invalid_direction), do: "direction must be asc or desc"

  defp list_error_detail(:invalid_archived),
    do: "archived must be exclude, include, or only"

  defp list_error_detail(:invalid_property),
    do: "property must be comma-separated definitionId:value pairs"

  defp list_error_detail(:bad_cursor), do: "cursor does not match the current query"

  defp not_found(conn), do: render_error(conn, :not_found, %{detail: "Item not found"})

  defp bad_request(conn, detail), do: render_error(conn, :bad_request, %{detail: detail})

  defp render_error(conn, status, assigns) do
    conn
    |> put_status(status)
    |> put_view(@view)
    |> render(:error, assigns)
  end

  defp changeset_detail(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
    |> case do
      "" -> "Invalid item payload"
      detail -> detail
    end
  end

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
