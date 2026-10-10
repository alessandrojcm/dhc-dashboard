defmodule DhcWeb.BeginnersWorkshopDoorController do
  @moduledoc """
  The `beginnersWorkshopDoor` slice (ALE-379): a workshop's door view.

  The router admits any member (`beginners.workshops.assigned.read`);
  `beginners.workshops.run` is assignment-scoped, so this controller checks
  it against the workshop's Staff. Anyone who is neither on the Staff nor a
  manager gets the same 404 as an unknown workshop: they cannot tell the
  workshop exists.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.Auth.Capabilities
  alias Dhc.BeginnersWorkshops

  @doc "GET /beginners-workshops/{id}/door"
  def show(conn, %{"id" => id}) do
    with {:ok, view, resource} <- BeginnersWorkshops.door_view(id),
         :ok <- authorize(conn, resource) do
      render(conn, :show, view: view)
    end
  end

  defp authorize(conn, resource) do
    case Capabilities.authorize(
           conn.assigns.current_session,
           :"beginners.workshops.run",
           resource
         ) do
      :ok -> :ok
      {:error, :inactive} -> {:error, :unauthorized}
      {:error, _concealed} -> {:error, :not_found}
    end
  end
end
