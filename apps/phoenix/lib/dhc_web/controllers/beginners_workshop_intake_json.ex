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
              endTime:
                page.workshop.end_time && BeginnersWorkshopsJSON.hh_mm(page.workshop.end_time),
              venue: page.workshop.venue,
              destinationName: page.workshop.destination_name,
              destinationAddress: page.workshop.destination_address,
              directionsUrl: page.workshop.directions_url,
              destinationProvider: page.workshop.destination_provider,
              destinationPlaceId: page.workshop.destination_place_id
            },
        feeCents: page.fee_cents,
        paymentCutoff: page.payment_cutoff
      }
    }
  end

  def checkout(%{checkout: checkout}),
    do: %{
      data: %{
        checkoutUrl: checkout.checkout_url,
        clientSecret: checkout.client_secret,
        sessionId: checkout.session_id
      }
    }
end
