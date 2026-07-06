defmodule DhcWeb.WaitlistController do
  use DhcWeb, :controller

  alias Dhc.Waitlist

  @doc """
  GET /waitlist/status
  """
  def index(conn, _params) do
    conn
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:status, status: Waitlist.status())
  end

  @doc """
  GET /waitlist/analytics
  """
  def analytics(conn, _params) do
    conn
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:analytics, analytics: Waitlist.analytics())
  end

  @doc """
  GET /waitlist/entries
  """
  def entries(conn, params) do
    case Waitlist.entries(params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:entries, result: result)

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or mismatched cursor")

      {:error, _reason} ->
        bad_request(conn, "Invalid waitlist entries query")
    end
  end

  @doc """
  POST /waitlist/entries
  """
  def create(conn, params) do
    case Waitlist.create_entry(params) do
      {:ok, entry} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:create, entry: entry)

      {:error, :duplicate_email} ->
        conflict(conn, "This email is already on the waitlist")

      {:error, :waitlist_closed} ->
        forbidden(conn, "Waitlist is closed")

      {:error, :invalid_payload} ->
        unprocessable(conn, "Invalid waitlist entry payload")

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  GET /waitlist/entries/:id
  """
  def show(conn, %{"id" => id}) do
    case Waitlist.get_entry(id) do
      {:ok, entry} ->
        conn
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:show, entry: entry)

      {:error, :not_found} ->
        not_found(conn, "Waitlist entry not found")
    end
  end

  @doc """
  PATCH /waitlist/entries/:id
  """
  def update(conn, %{"id" => id} = params) do
    case Waitlist.update_entry(id, Map.delete(params, "id")) do
      {:ok, entry} ->
        conn
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:show, entry: entry)

      {:error, :not_found} ->
        not_found(conn, "Waitlist entry not found")

      {:error, :invalid_status} ->
        unprocessable(conn, "Invalid waitlist status")

      {:error, :invalid_payload} ->
        unprocessable(conn, "Invalid waitlist entry update payload")

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc """
  GET /waitlist/entries/:id/guardian
  """
  def guardian(conn, %{"id" => id}) do
    case Waitlist.get_guardian(id) do
      {:ok, guardian} ->
        conn
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:guardian, guardian: guardian)

      {:error, :not_found} ->
        not_found(conn, "Waitlist entry not found")
    end
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end

  defp conflict(conn, detail) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: detail}})
  end

  defp forbidden(conn, detail) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: detail}})
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: detail}})
  end

  defp unprocessable(conn, detail) when is_binary(detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> render_error_detail()

    unprocessable(conn, detail)
  end

  defp render_error_detail(errors) when errors == %{}, do: "Invalid waitlist entry payload"

  defp render_error_detail(errors) do
    Enum.map_join(errors, "; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end
end
