defmodule DhcWeb.HealthController do
  use DhcWeb, :controller

  @doc """
  GET /health
  """
  def index(conn, _params) do
    json(conn, %{data: %{status: "ok"}})
  end
end
