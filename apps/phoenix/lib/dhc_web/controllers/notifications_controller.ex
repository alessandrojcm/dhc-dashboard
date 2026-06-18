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

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
