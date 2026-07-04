defmodule DhcWeb.SettingsController do
  @moduledoc false

  use DhcWeb, :controller

  alias Dhc.Settings

  @doc """
  GET /settings
  """
  def index(conn, _params) do
    settings = Settings.list()

    conn
    |> put_view(json: DhcWeb.SettingsJSON)
    |> render(:index, settings: settings)
  end

  @doc """
  PATCH /settings/{key}
  """
  def update(conn, %{"key" => key} = params) do
    value = Map.get(params, "value")

    case Settings.update(key, value) do
      {:ok, item} ->
        conn
        |> put_view(json: DhcWeb.SettingsJSON)
        |> render(:show, setting: item)

      {:error, :not_found} ->
        not_found(conn, "Unknown or non-allowlisted setting key")

      {:error, :missing} ->
        server_error(conn, "Configured setting row not found")

      {:error, :invalid_value, detail} ->
        unprocessable(conn, detail)

      {:error, :no_value} ->
        unprocessable(conn, "value is required")
    end
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
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
