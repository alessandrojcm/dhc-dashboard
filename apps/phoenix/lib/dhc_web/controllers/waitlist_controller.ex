defmodule DhcWeb.WaitlistController do
  use DhcWeb, :controller

  alias Dhc.Waitlist

  action_fallback DhcWeb.WaitlistHTTP

  @doc """
  GET /waitlist/status
  """
  def index(conn, _params) do
    conn
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:status, status: Waitlist.status())
  end

  @doc """
  PATCH /waitlist/status
  """
  def update_status(conn, %{"isOpen" => is_open}) when is_boolean(is_open) do
    case Waitlist.set_open(is_open) do
      {:ok, status} ->
        conn
        |> put_view(json: DhcWeb.WaitlistJSON)
        |> render(:status, status: status)

      {:error, :not_found} ->
        {:error, :setting_not_found}
    end
  end

  def update_status(_conn, _params), do: {:error, :invalid_is_open}

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

      error ->
        DhcWeb.Problem.list_error(error)
    end
  end

  @doc """
  POST /waitlist/entries

  Public, so it must not be an email oracle: an email already on the waitlist
  answers exactly like a new entry (same status, same body, no entry data).
  """
  def create(conn, params) do
    case Waitlist.create_entry(params) do
      {:ok, _entry} -> render_received(conn)
      {:error, :duplicate_email} -> render_received(conn)
      error -> error
    end
  end

  defp render_received(conn) do
    conn
    |> put_status(:accepted)
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:create)
  end

  @doc """
  GET /waitlist/entries/:id
  """
  def show(conn, %{"id" => id}) do
    with {:ok, entry} <- Waitlist.get_entry(id) do
      conn
      |> put_view(json: DhcWeb.WaitlistJSON)
      |> render(:show, entry: entry)
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

      {:error, :invalid_payload} ->
        {:error, :invalid_update}

      error ->
        error
    end
  end

  @doc """
  GET /waitlist/entries/:id/guardian
  """
  def guardian(conn, %{"id" => id}) do
    with {:ok, guardian} <- Waitlist.get_guardian(id) do
      conn
      |> put_view(json: DhcWeb.WaitlistJSON)
      |> render(:guardian, guardian: guardian)
    end
  end
end
