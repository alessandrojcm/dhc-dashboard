defmodule DhcWeb.BeginnersWorkshopsJSON do
  @moduledoc """
  Renders `Dhc.BeginnersWorkshops.WorkshopProjection` views. Civil times are
  `HH:MM` Europe/Dublin; the cutoff instant is ISO 8601 UTC.
  """

  def index(%{result: %{upcoming: upcoming, past: past}}),
    do: %{data: %{upcoming: Enum.map(upcoming, &workshop/1), past: Enum.map(past, &workshop/1)}}

  def schedule(%{result: workshops}), do: %{data: Enum.map(workshops, &workshop/1)}

  def show(%{result: workshop}), do: %{data: workshop(workshop)}

  def staff_candidates(%{result: candidates}),
    do: %{
      data: Enum.map(candidates, &%{principalId: &1.principal_id, name: &1.name, coach: &1.coach})
    }

  @doc "The Staff of a workshop, shared with the door view."
  def staff(%{coach: coach, assistants: assistants}),
    do: %{coach: coach && staff_member(coach), assistants: Enum.map(assistants, &staff_member/1)}

  defp staff_member(member), do: %{principalId: member.principal_id, name: member.name}

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
      alerts: view.alerts,
      staff: staff(view.staff)
    }
  end

  @doc false
  def hh_mm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
end
