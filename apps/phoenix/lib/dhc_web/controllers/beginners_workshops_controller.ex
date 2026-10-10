defmodule DhcWeb.BeginnersWorkshopsController do
  @moduledoc """
  The `beginnersWorkshops` slice (ALE-378): the Workshops list, scheduling
  and settings. The router gates every action on
  `beginners.workshops.manage`; the boundary authorizes the actor again
  before any read.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "GET /beginners-workshops"
  def index(conn, _params) do
    {:ok, BeginnersWorkshops.list_workshops()}
    |> BeginnersWorkshopsHTTP.respond(conn, :index)
  end

  @doc "POST /beginners-workshops"
  def create(conn, params) do
    with {:ok, workshops} <- BeginnersWorkshopsHTTP.schedule_attrs(params) do
      BeginnersWorkshops.execute(
        BeginnersWorkshopsHTTP.actor(conn),
        {:schedule_workshop, workshops}
      )
    end
    |> BeginnersWorkshopsHTTP.respond(conn, :schedule, :created)
  end

  @doc "PUT /beginners-workshops/{id}/settings"
  def update_settings(conn, %{"id" => id} = params) do
    BeginnersWorkshops.execute(
      BeginnersWorkshopsHTTP.actor(conn),
      {:update_workshop, id, BeginnersWorkshopsHTTP.attrs(params)}
    )
    |> BeginnersWorkshopsHTTP.respond(conn, :show)
  end
end
