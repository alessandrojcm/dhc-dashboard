defmodule DhcWeb.BeginnersWorkshopFastTrackController do
  @moduledoc """
  The `beginnersWorkshopFastTrack` slice (ALE-384): the Fast-track dialog's
  search and the two ways to place a person — an existing Waitlist entry, or
  a new person's registration details through the staff "add a new person"
  path. The router gates every action on `beginners.workshops.manage`; the
  boundary authorizes the actor again before any read.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "GET /beginners-workshops/{id}/fast-track/candidates"
  def candidates(conn, %{"id" => id} = params) do
    id
    |> BeginnersWorkshops.fast_track_candidates(Map.get(params, "q"))
    |> BeginnersWorkshopsHTTP.respond(conn, :candidates)
  end

  @doc "POST /beginners-workshops/{id}/fast-track"
  def waitlist_person(conn, %{"id" => id} = params) do
    command(conn, id, {:waitlist_entry, Map.get(params, "waitlistId")})
  end

  @doc "POST /beginners-workshops/{id}/fast-track/new-person"
  def new_person(conn, %{"id" => id} = params) do
    command(conn, id, {:new_person, Map.delete(params, "id")})
  end

  defp command(conn, id, person) do
    conn
    |> BeginnersWorkshopsHTTP.actor()
    |> BeginnersWorkshops.execute({:fast_track, id, person})
    |> BeginnersWorkshopsHTTP.respond(conn, :show, :created)
  end
end
