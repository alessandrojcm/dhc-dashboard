defmodule DhcWeb.BeginnersWorkshopDoorJSON do
  @moduledoc """
  Renders `Dhc.BeginnersWorkshops.DoorView`: the door view's own closed
  shape. Never add email, payment, refund or Waitlist fields here.
  """

  alias DhcWeb.BeginnersWorkshopsJSON

  def show(%{view: view}) do
    %{
      data: %{
        id: view.id,
        status: view.status,
        venue: view.venue,
        date: view.date,
        startTime: BeginnersWorkshopsJSON.hh_mm(view.start_time),
        stage: view.stage,
        alerts: view.alerts,
        staff: BeginnersWorkshopsJSON.staff(view.staff)
      }
    }
  end
end
