defmodule DhcWeb.InventoryCatalogController do
  @moduledoc """
  The member-facing inventory catalog — ALE-285.

    * GET  /inventory/catalog/items                        — browse, any member.
    * GET  /inventory/catalog/items/:slugOrId              — detail, any member.
    * POST /inventory/catalog/items/:slugOrId/requests     — request, any member.

  **Member-readable by design, and deliberately not the operator viewer.**
  `DhcWeb.InventoryOperatorItemsController` discloses the container location,
  operator notes, and maintenance facts, which spec ALE-280 story 45 forbids
  showing members in ordinary browsing. This controller serves a different
  read model (`Dhc.Inventory.MemberCatalog`) whose rows cannot carry those
  fields at all, rather than filtering them out of a shared one.

  Access follows membership rather than a role list: the `:authenticated_api`
  pipeline requires an active session, and an inactive member cannot hold one
  (story 46), so "any authenticated member" is already "any active member".

  The request command lives here rather than on the loan controller because
  a request is addressed to an *item* — the item is the thing whose
  availability gates it. Reading and cancelling an existing loan is
  `DhcWeb.InventoryMemberLoansController`.

  The controller only maps `Dhc.Inventory` result tuples onto status codes.
  Unavailability and duplicate requests become `409` with a machine-readable
  code that stays generic; nothing surfaces as a server error.
  """

  use DhcWeb, :controller

  alias Dhc.Inventory

  @view [json: DhcWeb.InventoryCatalogJSON]

  # Domain reasons meaning "an interlock refused this", not "you sent
  # something invalid". `item_unavailable` intentionally explains nothing
  # further: a member must not learn who holds an item or why it is out.
  @conflict_codes %{
    item_unavailable: "The item cannot be requested right now",
    duplicate_request: "You already have a pending request for this item"
  }

  @validation_codes %{
    invalid_dates:
      "startsOn and dueOn must be dates today or later, with dueOn on or after startsOn",
    invalid_note: "note must be text"
  }

  @doc """
  GET /inventory/catalog/items
  """
  def list_items(conn, params) do
    case Inventory.list_catalog_items(params) do
      {:ok, page} -> conn |> put_view(@view) |> render(:index, page: page)
      {:error, reason} -> bad_request(conn, list_error_detail(reason))
    end
  end

  @doc """
  GET /inventory/catalog/items/:slugOrId
  """
  def show_item(conn, %{"slugOrId" => slug_or_id}) do
    case Inventory.resolve_catalog_item(slug_or_id) do
      {:ok, item} -> conn |> put_view(@view) |> render(:show, item: item)
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc """
  POST /inventory/catalog/items/:slugOrId/requests
  """
  def request_loan(conn, %{"slugOrId" => slug_or_id} = params) do
    slug_or_id
    |> Inventory.request_loan(params, actor_id(conn))
    |> respond_loan(conn, :created)
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp respond_loan({:ok, loan}, conn, status) do
    conn |> put_status(status) |> put_view(@view) |> render(:loan, loan: loan)
  end

  defp respond_loan({:error, :not_found}, conn, _status), do: not_found(conn)

  defp respond_loan({:error, reason}, conn, _status) when is_map_key(@conflict_codes, reason) do
    render_error(conn, :conflict, %{
      detail: Map.fetch!(@conflict_codes, reason),
      code: to_string(reason)
    })
  end

  defp respond_loan({:error, reason}, conn, _status) when is_map_key(@validation_codes, reason) do
    render_error(conn, :unprocessable_entity, %{
      detail: Map.fetch!(@validation_codes, reason),
      code: to_string(reason)
    })
  end

  defp list_error_detail(:invalid_limit), do: "limit must be one of 10, 25, 50, 100"
  defp list_error_detail(:invalid_direction), do: "direction must be asc or desc"

  defp list_error_detail(:invalid_category),
    do: "categoryId must be comma-separated category UUIDs"

  defp list_error_detail(:invalid_property),
    do: "property must be comma-separated definitionId:value pairs"

  defp list_error_detail(:bad_cursor), do: "cursor does not match the current query"

  defp not_found(conn), do: render_error(conn, :not_found, %{detail: "Item not found"})
  defp bad_request(conn, detail), do: render_error(conn, :bad_request, %{detail: detail})

  defp render_error(conn, status, assigns) do
    conn |> put_status(status) |> put_view(@view) |> render(:error, assigns)
  end

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
