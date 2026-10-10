defmodule DhcWeb.BeginnersWorkshopIntakesController do
  @moduledoc """
  The `beginnersWorkshopIntakes` slice (ALE-386): the console's Intake
  commands — Decline, Cancel with refund (ALE-387), Withdraw (ALE-387),
  Resend link and Rotate link — each with an optional note recorded in the
  Intake's history, plus the Waitlist tab's Withdraw of a person. The
  router gates them on their capability (`beginners.workshops.manage`;
  withdraw `beginners.waitlist.manage`); the boundary authorizes the actor
  again before any read and decides with `IntakePolicy` under the lock.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/decline"
  def decline(conn, params), do: command(conn, :decline, params)

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/cancel-with-refund"
  def cancel_with_refund(conn, params), do: command(conn, :cancel_with_refund, params)

  @doc """
  POST /beginners-workshops/{id}/intakes/{intakeId}/withdraw — the router
  gates it on `beginners.waitlist.manage`, like the Waitlist tab's.
  """
  def withdraw(conn, params), do: command(conn, :withdraw, params)

  @doc """
  POST /beginners-workshops/people/{waitlistId}/withdraw (ALE-387): the
  Waitlist tab's withdraw, which names the person. It runs in the
  Beginners' Workshop boundary because it may close their open Intake;
  `Dhc.Waitlist` never calls it.
  """
  def withdraw_person(conn, %{"waitlistId" => waitlist_id} = params) do
    conn
    |> BeginnersWorkshopsHTTP.actor()
    |> BeginnersWorkshops.execute({:withdraw, waitlist_id, command_attrs(params)})
    |> BeginnersWorkshopsHTTP.respond(conn, :withdraw_person)
  end

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/resend-link"
  def resend_link(conn, params), do: command(conn, :resend_link, params)

  @doc "POST /beginners-workshops/{id}/intakes/{intakeId}/rotate-link"
  def rotate_link(conn, params), do: command(conn, :rotate_link, params)

  defp command(conn, name, %{"id" => id, "intakeId" => intake_id} = params) do
    conn
    |> BeginnersWorkshopsHTTP.actor()
    |> BeginnersWorkshops.execute({name, id, intake_id, command_attrs(params)})
    |> BeginnersWorkshopsHTTP.respond(conn, :intake_command)
  end

  # The note, and `withdraw`'s refund-or-forfeit choice; the boundary
  # ignores what a command does not take.
  defp command_attrs(params), do: Map.take(params, ["note", "refund"])
end
