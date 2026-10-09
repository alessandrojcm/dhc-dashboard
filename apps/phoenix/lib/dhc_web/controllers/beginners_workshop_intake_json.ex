defmodule DhcWeb.BeginnersWorkshopIntakeJSON do
  @moduledoc """
  Renders the Intake page view (`Dhc.BeginnersWorkshops.IntakePage`). Civil
  date and `HH:MM` start time are Europe/Dublin.
  """

  alias DhcWeb.BeginnersWorkshopsJSON

  def show(%{page: page}) do
    %{
      data: %{
        state: page.state,
        action: page.action,
        closedReason: page.closed_reason,
        firstName: page.first_name,
        workshop:
          page.workshop &&
            %{
              date: page.workshop.date,
              startTime: BeginnersWorkshopsJSON.hh_mm(page.workshop.start_time),
              venue: page.workshop.venue
            },
        feeCents: page.fee_cents
      }
    }
  end

  def checkout(%{checkout_url: url}), do: %{data: %{checkoutUrl: url}}
end
