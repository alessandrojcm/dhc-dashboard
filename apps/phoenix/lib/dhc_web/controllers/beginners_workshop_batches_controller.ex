defmodule DhcWeb.BeginnersWorkshopBatchesController do
  @moduledoc """
  The `beginnersWorkshopBatches` slice (ALE-380): pausing and resuming a
  workshop's automatic Batches. Coordinators never send a Batch by hand;
  Batches come only from the system sweep. The router gates both actions on
  `beginners.workshops.manage`; the boundary authorizes the actor again
  before any read.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "POST /beginners-workshops/{id}/batches/pause"
  def pause(conn, %{"id" => id}),
    do: BeginnersWorkshopsHTTP.command(conn, {:pause_batches, id}, :show)

  @doc "POST /beginners-workshops/{id}/batches/resume"
  def resume(conn, %{"id" => id}),
    do: BeginnersWorkshopsHTTP.command(conn, {:resume_batches, id}, :show)
end
