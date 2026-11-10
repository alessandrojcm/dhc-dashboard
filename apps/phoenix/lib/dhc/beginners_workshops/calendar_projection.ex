defmodule Dhc.BeginnersWorkshops.CalendarProjection do
  @moduledoc false

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, WorkshopPolicy}
  alias Dhc.ClubCalendar
  alias Dhc.Destinations

  @title "Beginners' Workshop"

  @spec project(BeginnersWorkshop.t()) :: %{
          id: binary(),
          title: String.t(),
          status: String.t(),
          start_date: DateTime.t() | nil,
          end_date: DateTime.t() | nil,
          location: String.t()
        }
  def project(%BeginnersWorkshop{} = workshop) do
    {start_date, end_date} = schedule(workshop)

    %{
      id: workshop.id,
      title: @title,
      status: calendar_status(workshop.status),
      start_date: start_date,
      end_date: end_date,
      # ALE-441: the recognizable destination name/address when one is
      # stored, else the short venue label; never a link.
      location:
        Destinations.calendar_location(
          workshop.destination_name,
          workshop.destination_address,
          workshop.venue
        )
    }
  end

  @spec current?(BeginnersWorkshop.t(), DateTime.t()) :: boolean()
  def current?(%BeginnersWorkshop{status: "cancelled"}, %DateTime{}), do: true

  def current?(%BeginnersWorkshop{} = workshop, %DateTime{} = now) do
    case project(workshop) do
      %{end_date: %DateTime{} = end_date} -> DateTime.compare(end_date, now) == :gt
      %{start_date: %DateTime{} = start_date} -> DateTime.compare(start_date, now) == :gt
      _ -> false
    end
  end

  defp schedule(%{date: %Date{}, start_time: %Time{}} = workshop) do
    start_date = ClubCalendar.to_utc(workshop.date, workshop.start_time)

    end_date =
      if WorkshopPolicy.valid_end_time?(workshop) do
        ClubCalendar.to_utc(workshop.date, workshop.end_time)
      end

    {start_date, end_date}
  end

  defp schedule(_workshop), do: {nil, nil}

  defp calendar_status("cancelled"), do: "cancelled"
  defp calendar_status(_status), do: "scheduled"
end
