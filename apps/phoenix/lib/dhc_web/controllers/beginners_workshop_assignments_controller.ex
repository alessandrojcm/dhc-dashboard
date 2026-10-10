defmodule DhcWeb.BeginnersWorkshopAssignmentsController do
  @moduledoc """
  The `beginnersWorkshopAssignments` slice (ALE-379): "My Beginners'
  Workshops", the caller's own upcoming and same-day Staff assignments. The
  router gates it on `beginners.workshops.assigned.read` (every member); the
  only input is the session's own principal.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops

  @doc "GET /beginners-workshops/mine"
  def list(conn, _params) do
    render(conn, :list,
      rows: BeginnersWorkshops.my_workshops(conn.assigns.current_session.principal.id)
    )
  end
end
