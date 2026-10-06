defmodule DhcWeb.SettingsController do
  @moduledoc false

  use DhcWeb, :controller

  alias Dhc.Settings

  action_fallback DhcWeb.SettingsHTTP

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

      {:error, :invalid_value, detail} ->
        {:error, [detail]}

      error ->
        error
    end
  end
end
