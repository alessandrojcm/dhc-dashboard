defmodule DhcWeb.WorkshopsController do
  use DhcWeb, :controller

  alias Dhc.Workshops

  @doc """
  GET /workshops/calendar

  Returns non-cancelled Workshops for the coordinator management calendar,
  with interest and pending/confirmed registration counts. RBAC is enforced
  by the `:workshop_coordinator_api` pipeline (`workshop_coordinator`,
  `president`, `admin`) — see the `Dhc.Workshops` moduledoc for the
  historical `beginners_coordinator` registration-visibility drift that this
  endpoint deliberately does not reproduce.

  The DTO carries no current-user registration or interest state; those were
  PostgREST join artifacts (PRD #142). Month/date-window pagination is out of
  scope, so the full non-cancelled set is returned.
  """
  def calendar(conn, _params) do
    workshops = Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))

    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:calendar, workshops: workshops)
  end

  @doc """
  GET /workshops

  Returns the member-safe Workshop collection. Status is constrained to
  `planned` and `published`, and each Workshop includes the current user's
  interest and registration state.
  """
  def list(conn, params) do
    workshops = Workshops.list_member_workshops(conn.assigns.current_user.sub, params)

    conn
    |> put_view(json: DhcWeb.WorkshopsJSON)
    |> render(:list, workshops: workshops)
  end
end
