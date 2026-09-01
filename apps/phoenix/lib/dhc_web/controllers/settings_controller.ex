defmodule DhcWeb.SettingsController do
  @moduledoc false

  use DhcWeb, :controller

  alias Dhc.Settings
  alias DhcWeb.ConditionalRequests

  @doc """
  GET /settings
  """
  def index(conn, _params) do
    settings = Settings.list()

    conn
    |> put_view(json: DhcWeb.SettingsJSON)
    |> render(:index, settings: settings)
  end

  @doc "GET /settings/{key}"
  def show(conn, %{"key" => key}) do
    case Settings.get(key) do
      {:ok, setting} ->
        precondition = ConditionalRequests.evaluate(conn, setting.lock_version)

        case ConditionalRequests.maybe_send_not_modified(conn, precondition) do
          %Plug.Conn{} = conn_304 -> conn_304
          {:ok, nil} -> setting_response(conn, setting)
          {:ok, if_match} -> enforce_get_if_match(conn, setting, if_match)
          {:error, reason} -> bad_request(conn, ConditionalRequests.error_detail(reason))
        end

      {:error, :not_found} ->
        not_found(conn, "Unknown or non-allowlisted setting key")

      {:error, :missing} ->
        server_error(conn, "Configured setting row not found")
    end
  end

  @doc """
  PATCH /settings/{key}
  """
  def update(conn, %{"key" => key} = params) do
    value = Map.get(params, "value")

    case ConditionalRequests.parse_if_match(conn) do
      {:ok, nil} ->
        apply_update(conn, key, value, [])

      {:ok, if_match} ->
        apply_update(conn, key, value, expected_lock_version: expected_version(if_match))

      {:error, reason} ->
        bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  defp enforce_get_if_match(conn, setting, if_match) do
    case ConditionalRequests.enforce_if_match(if_match, setting.lock_version) do
      :ok -> setting_response(conn, setting)
      {:precondition_failed} -> precondition_failed(conn, setting)
    end
  end

  defp expected_version({:version, version}), do: version
  defp expected_version({:any_existing, :*}), do: :*

  defp apply_update(conn, key, value, opts) do
    case Settings.update(key, value, opts) do
      {:ok, setting} -> setting_response(conn, setting)
      {:error, {:version_precondition_failed, current}} -> precondition_failed(conn, current)
      {:error, :not_found} -> not_found(conn, "Unknown or non-allowlisted setting key")
      {:error, :missing} -> server_error(conn, "Configured setting row not found")
      {:error, :invalid_value, detail} -> unprocessable(conn, detail)
      {:error, :no_value} -> unprocessable(conn, "value is required")
    end
  end

  defp setting_response(conn, setting) do
    conn
    |> ConditionalRequests.put_etag(setting.lock_version)
    |> put_view(json: DhcWeb.SettingsJSON)
    |> render(:show, setting: setting)
  end

  defp precondition_failed(conn, setting) do
    conn
    |> ConditionalRequests.put_etag(setting.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.SettingsJSON)
    |> render(:precondition_failed, setting: setting)
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: detail}})
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end

  defp server_error(conn, detail) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: %{detail: detail}})
  end

  defp unprocessable(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end
end
