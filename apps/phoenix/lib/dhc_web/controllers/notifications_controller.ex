defmodule DhcWeb.NotificationsController do
  use DhcWeb, :controller

  alias Dhc.Notifications

  action_fallback DhcWeb.NotificationsHTTP

  @doc """
  GET /notifications
  """
  def index(conn, params) do
    user_id = conn.assigns.current_session.principal.id

    case Notifications.list_for_user(user_id, params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.NotificationsJSON)
        |> render(:list, result: result)

      error ->
        DhcWeb.Problem.list_error(error)
    end
  end

  @doc "PATCH /notifications/:id/read"
  def mark_read(conn, %{"id" => notification_id}) do
    user_id = conn.assigns.current_session.principal.id

    with {:ok, notification} <- Notifications.mark_read(user_id, notification_id) do
      conn
      |> put_view(json: DhcWeb.NotificationsJSON)
      |> render(:show, notification: notification)
    end
  end

  @doc "POST /notifications/read-all"
  def mark_all_read(conn, _params) do
    {:ok, updated_count} = Notifications.mark_all_read(conn.assigns.current_session.principal.id)

    conn
    |> put_view(json: DhcWeb.NotificationsJSON)
    |> render(:mark_all_read, updated_count: updated_count)
  end
end
