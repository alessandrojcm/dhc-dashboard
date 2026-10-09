defmodule DhcWeb.BeginnersWorkshopsJSON do
  @moduledoc """
  Renders `Dhc.BeginnersWorkshops.WorkshopProjection` views. Civil times are
  `HH:MM` Europe/Dublin; the cutoff instant is ISO 8601 UTC.
  """

  def index(%{result: %{upcoming: upcoming, past: past}}),
    do: %{data: %{upcoming: Enum.map(upcoming, &workshop/1), past: Enum.map(past, &workshop/1)}}

  def schedule(%{result: workshops}), do: %{data: Enum.map(workshops, &workshop/1)}

  def show(%{result: workshop}), do: %{data: workshop(workshop)}

  defp workshop(view) do
    %{
      id: view.id,
      status: view.status,
      venue: view.venue,
      date: view.date,
      startTime: hh_mm(view.start_time),
      capacity: view.capacity,
      feeCents: view.fee_cents,
      paymentCutoff: view.payment_cutoff,
      paymentCutoffDate: view.payment_cutoff_date,
      paymentCutoffTime: hh_mm(view.payment_cutoff_time),
      contactFromDate: view.contact_from,
      contactFromEditable: view.contact_from_editable,
      paymentWindowDays: view.payment_window_days,
      stage: view.stage,
      seats: view.seats,
      alerts: view.alerts
    }
  end

  defp hh_mm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
end
