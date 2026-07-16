defmodule DhcWeb.NotificationsController do
  use DhcWeb, :controller

  alias Dhc.Notifications

  @doc """
  GET /notifications
  """
  def index(conn, params) do
    user_id = conn.assigns.current_user.sub

    case Notifications.list_for_user(user_id, params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.NotificationsJSON)
        |> render(:list, result: result)

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or mismatched cursor")

      {:error, _reason} ->
        bad_request(conn, "Invalid notifications query")
    end
  end

  @doc "PATCH /notifications/:id/read"
  def mark_read(conn, %{"id" => notification_id}) do
    user_id = conn.assigns.current_user.sub

    case Notifications.mark_read(user_id, notification_id) do
      {:ok, notification} ->
        conn
        |> put_view(json: DhcWeb.NotificationsJSON)
        |> render(:show, notification: notification)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Notification not found"}})
    end
  end

  @doc "POST /notifications/read-all"
  def mark_all_read(conn, _params) do
    {:ok, updated_count} = Notifications.mark_all_read(conn.assigns.current_user.sub)

    conn
    |> put_view(json: DhcWeb.NotificationsJSON)
    |> render(:mark_all_read, updated_count: updated_count)
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
