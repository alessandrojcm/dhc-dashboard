defmodule DhcWeb.BeginnersWorkshopReportController do
  @moduledoc """
  The `beginnersWorkshopReport` slice (ALE-397): the Dashboard tab's
  Beginners' Workshop report. Read only; the router gates it on
  `beginners.workshops.manage`, which is the report's whole authorization.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops

  @doc "GET /beginners-workshops/report"
  def show(conn, _params) do
    render(conn, :show, report: BeginnersWorkshops.report())
  end
end
