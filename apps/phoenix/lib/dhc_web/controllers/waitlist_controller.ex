defmodule DhcWeb.WaitlistController do
  use DhcWeb, :controller

  alias Dhc.Waitlist
  alias DhcWeb.ConditionalRequests

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
        not_found(conn, "Waitlist setting not found")
    end
  end

  def update_status(conn, _params), do: unprocessable(conn, "isOpen must be a boolean")

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
        show_entry(conn, entry)

      {:error, :not_found} ->
        not_found(conn, "Waitlist entry not found")
    end
  end

  defp show_entry(conn, entry) do
    case ConditionalRequests.evaluate(conn, entry.lock_version) do
      {:not_modified, etag} -> conn |> put_resp_header("etag", etag) |> send_resp(304, "")
      {:ok, nil} -> entry_response(conn, entry)
      {:ok, if_match} -> show_entry_if_match(conn, entry, if_match)
      {:error, reason} -> bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  defp show_entry_if_match(conn, entry, if_match) do
    if ConditionalRequests.enforce_if_match(if_match, entry.lock_version) == :ok,
      do: entry_response(conn, entry),
      else: precondition_failed(conn, entry)
  end

  @doc """
  PATCH /waitlist/entries/:id
  """
  def update(conn, %{"id" => id} = params) do
    opts =
      case ConditionalRequests.parse_if_match(conn) do
        {:ok, nil} -> []
        {:ok, {:version, version}} -> [expected_lock_version: version]
        {:ok, {:any_existing, :*}} -> [expected_lock_version: :*]
        {:error, reason} -> {:error, reason}
      end

    case opts do
      {:error, reason} -> bad_request(conn, ConditionalRequests.error_detail(reason))
      opts -> update_entry(conn, id, Map.delete(params, "id"), opts)
    end
  end

  defp update_entry(conn, id, attrs, opts) do
    case Waitlist.update_entry(id, attrs, opts) do
      {:ok, entry} ->
        entry_response(conn, entry)

      {:error, {:version_precondition_failed, current}} ->
        precondition_failed(conn, current)

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

  defp entry_response(conn, entry) do
    conn
    |> ConditionalRequests.put_etag(entry.lock_version)
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:show, entry: entry)
  end

  defp precondition_failed(conn, entry) do
    conn
    |> ConditionalRequests.put_etag(entry.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.WaitlistJSON)
    |> render(:precondition_failed, entry: entry)
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
