defmodule DhcWeb.Router do
  use DhcWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", DhcWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end
end
