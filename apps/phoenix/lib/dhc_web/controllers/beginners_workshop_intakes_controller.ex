defmodule DhcWeb.BeginnersWorkshopIntakesController do
  @moduledoc """
  The `beginnersWorkshopIntakes` slice (ALE-386): the console's Intake
  commands — Decline, Resend link and Rotate link — each with an optional
  note recorded in the Intake's history. The router gates them on
  `beginners.workshops.manage`; the boundary authorizes the actor again
  before any read and decides with `IntakePolicy` under the lock.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/decline"
  def decline(conn, params), do: command(conn, :decline, params)

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/resend-link"
  def resend_link(conn, params), do: command(conn, :resend_link, params)

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/rotate-link"
  def rotate_link(conn, params), do: command(conn, :rotate_link, params)

  defp command(conn, name, %{"id" => id, "intakeId" => intake_id} = params) do
    conn
    |> BeginnersWorkshopsHTTP.actor()
    |> BeginnersWorkshops.execute({name, id, intake_id, Map.take(params, ["note"])})
    |> BeginnersWorkshopsHTTP.respond(conn, :intake_command)
  end
end
