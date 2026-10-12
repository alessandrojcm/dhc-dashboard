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
        staff: BeginnersWorkshopsJSON.staff(view.staff),
        checkIn: %{window: view.check_in.window, opensAt: view.check_in.opens_at},
        people: Enum.map(view.people, &person/1),
        finalisation: finalisation(view.finalisation)
      }
    }
  end

  defp finalisation(nil), do: nil

  defp finalisation(finalisation) do
    %{
      at: finalisation.at,
      by: finalisation.by,
      attended: finalisation.attended,
      noShow: finalisation.no_show
    }
  end

  defp person(person) do
    %{
      id: person.id,
      firstName: person.first_name,
      lastName: person.last_name,
      pronouns: person.pronouns,
      state: person.state,
      minor: person.minor,
      medicalConditions: person.medical_conditions,
      guardian:
        person.guardian &&
          %{name: person.guardian.name, phoneNumber: person.guardian.phone_number},
      checkedIn: person.checked_in && %{at: person.checked_in.at, by: person.checked_in.by}
    }
  end
end
