defmodule DhcWeb.BeginnersWorkshopDoorController do
  @moduledoc """
  The `beginnersWorkshopDoor` slice (ALE-379): a workshop's door view.

  The router admits any member (`beginners.workshops.assigned.read`);
  `beginners.workshops.run` is assignment-scoped, so this controller checks
  it against the workshop's Staff. Anyone who is neither on the Staff nor a
  manager gets the same 404 as an unknown workshop: they cannot tell the
  workshop exists.

  `check_in` / `undo_check_in` (ALE-390) run the boundary command, which
  authorizes the same capability against the same Staff before any read, and
  answer the refreshed door view, as does `finish` (ALE-391: Attendance
  Finalisation from the door).
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.Auth.Capabilities
  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "GET /beginners-workshops/{id}/door"
  def show(conn, %{"id" => id}) do
    with {:ok, view, resource} <- BeginnersWorkshops.door_view(id),
         :ok <- authorize(conn, resource) do
      render(conn, :show, view: view)
    end
  end

  @doc "POST /beginners-workshops/{id}/door/people/{intakeId}/check-in"
  def check_in(conn, %{"id" => id, "intakeId" => intake_id}),
    do: run(conn, id, {:check_in, id, intake_id})

  @doc "DELETE /beginners-workshops/{id}/door/people/{intakeId}/check-in"
  def undo_check_in(conn, %{"id" => id, "intakeId" => intake_id}),
    do: run(conn, id, {:undo_check_in, id, intake_id})

  @doc "POST /beginners-workshops/{id}/door/finish"
  def finish(conn, %{"id" => id}), do: run(conn, id, {:finish_workshop, id})

  defp run(conn, id, command) do
    with {:ok, _record} <- BeginnersWorkshops.execute(BeginnersWorkshopsHTTP.actor(conn), command),
         {:ok, view, _resource} <- BeginnersWorkshops.door_view(id) do
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
