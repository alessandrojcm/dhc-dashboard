defmodule DhcWeb.WorkshopsController do
  use DhcWeb, :controller

  alias Dhc.Workshops

  @moduledoc """
  Workshop management reads.

  `calendar/2` and `attendees/2` are protected by the `:workshop_coordinator_api`
  pipeline (`workshop_coordinator`, `president`, `admin`). `list/2` is
  authenticated-only.

  See `Dhc.Workshops` for the historical `beginners_coordinator`
  registration-visibility drift that the coordinator endpoints deliberately
  do not reproduce.
  """

  @doc """
  GET /workshops/calendar

  Returns non-cancelled Workshops for the coordinator management calendar,
  with interest and pending/confirmed registration counts.

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

  @doc """
  GET /workshops/{id}/attendees

  Returns the combined coordinator attendee/refund management payload for a
  single Workshop: Workshop summary, active attendees (pending/confirmed),
  and refunds. Returns 404 when no Workshop exists for the given id.
  """
  def attendees(conn, %{"id" => id}) do
    case Workshops.workshop_attendees_and_refunds(id) do
      %{workshop: nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Workshop not found"}})

      %{workshop: workshop, attendees: attendees, refunds: refunds} ->
        conn
        |> put_view(json: DhcWeb.WorkshopsJSON)
        |> render(:attendees, workshop: workshop, attendees: attendees, refunds: refunds)
    end
  end
end
