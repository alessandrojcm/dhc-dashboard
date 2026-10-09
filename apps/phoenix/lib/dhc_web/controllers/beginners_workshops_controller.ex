defmodule DhcWeb.BeginnersWorkshopsController do
  @moduledoc """
  The `beginnersWorkshops` slice (ALE-378): the Workshops list, scheduling,
  settings, (ALE-379) Staff and (ALE-380) the console read model. The
  router gates every action on `beginners.workshops.manage`; the boundary
  authorizes the actor again before any read.
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

  @doc "GET /beginners-workshops/{id}/console"
  def console(conn, %{"id" => id}) do
    id
    |> BeginnersWorkshops.workshop_console()
    |> BeginnersWorkshopsHTTP.respond(conn, :console)
  end

  @doc "GET /beginners-workshops/staff-candidates"
  def staff_candidates(conn, _params) do
    {:ok, BeginnersWorkshops.staff_candidates()}
    |> BeginnersWorkshopsHTTP.respond(conn, :staff_candidates)
  end

  @doc "PUT /beginners-workshops/{id}/staff"
  def set_staff(conn, %{"id" => id} = params) do
    BeginnersWorkshops.execute(
      BeginnersWorkshopsHTTP.actor(conn),
      {:set_staff, id, BeginnersWorkshopsHTTP.staff_attrs(params)}
    )
    |> BeginnersWorkshopsHTTP.respond(conn, :show)
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
