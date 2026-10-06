defmodule DhcWeb.InventoryCatalogController do
  @moduledoc """
  The member-facing inventory catalog — ALE-285.

    * GET  /inventory/catalog/items                        — browse, any member.
    * GET  /inventory/catalog/items/:slugOrId              — detail, any member.
    * POST /inventory/catalog/items/:slugOrId/requests     — request, any member.

  **Member-readable by design, and deliberately not the operator viewer.**
  `DhcWeb.InventoryItemsController` discloses the container location,
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

  The controller renders successes and enqueues keyed operator notifications
  after a successful request; `DhcWeb.InventoryHTTP` maps every error.
  Unavailability and duplicate requests become `409` with a machine-readable
  code that stays generic. Enqueue failure is a `500` before the client is
  told the request succeeded.
  """

  use DhcWeb, :controller

  require Logger

  alias Dhc.Inventory

  action_fallback DhcWeb.InventoryHTTP

  @view [json: DhcWeb.InventoryCatalogJSON]

  @doc """
  GET /inventory/catalog/items
  """
  def list_items(conn, params) do
    with {:ok, page} <- Inventory.list_catalog_items(params) do
      conn |> put_view(@view) |> render(:index, page: page)
    end
  end

  @doc """
  GET /inventory/catalog/items/:slugOrId
  """
  def show_item(conn, %{"slugOrId" => slug_or_id}) do
    with {:ok, item} <- slug_or_id |> Inventory.resolve_catalog_item() |> item_error() do
      conn |> put_view(@view) |> render(:show, item: item)
    end
  end

  @doc """
  POST /inventory/catalog/items/:slugOrId/requests
  """
  def request_loan(conn, %{"slugOrId" => slug_or_id} = params) do
    with {:ok, loan} <-
           slug_or_id
           |> Inventory.request_loan(params, actor_id(conn))
           |> item_error()
           |> notify(:requested) do
      conn |> put_status(:created) |> put_view(@view) |> render(:loan, loan: loan)
    end
  end

  # ── Result mapping ──────────────────────────────────────────────

  defp notify({:ok, loan} = ok, kind) do
    case Inventory.notify_loan_transition(loan, kind) do
      {:ok, :enqueued} ->
        ok

      :ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "[inventory] loan notification enqueue failed loan_id=#{loan.id} kind=#{kind} reason=#{inspect(reason)}"
        )

        {:error, :notification_enqueue_failed}
    end
  end

  defp notify(error, _kind), do: error

  # This slice's `:not_found` is always the addressed catalog Item.
  defp item_error({:error, :not_found}), do: {:error, :item_not_found}
  defp item_error(result), do: result

  defp actor_id(conn), do: conn.assigns.current_session.principal.id
end
