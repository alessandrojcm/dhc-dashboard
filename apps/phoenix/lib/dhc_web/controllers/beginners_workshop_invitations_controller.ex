defmodule DhcWeb.BeginnersWorkshopInvitationsController do
  @moduledoc """
  The `beginnersWorkshopInvitations` slice (ALE-392): the cross-workshop
  Invitable view and the one-click Invitation of an attended person. The
  router gates both on `members.invite`; the boundary authorizes the actor
  again before any read. Invitations are then managed with the existing
  Invitations table (resend, delete).
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "GET /beginners-workshops/invitable"
  def invitable(conn, _params) do
    render(conn, :invitable, result: BeginnersWorkshops.invitable())
  end

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/invite"
  def invite(conn, %{"id" => id, "intakeId" => intake_id}) do
    conn
    |> BeginnersWorkshopsHTTP.actor()
    |> BeginnersWorkshops.execute({:invite, id, intake_id})
    |> BeginnersWorkshopsHTTP.respond(conn, :invite, :created)
  end
end
