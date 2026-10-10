defmodule DhcWeb.BeginnersWorkshopsJSON do
  @moduledoc """
  Renders `Dhc.BeginnersWorkshops.WorkshopProjection` views. Civil times are
  `HH:MM` Europe/Dublin; the cutoff instant is ISO 8601 UTC.
  """

  def index(%{result: %{upcoming: upcoming, past: past}}),
    do: %{data: %{upcoming: Enum.map(upcoming, &workshop/1), past: Enum.map(past, &workshop/1)}}

  def schedule(%{result: workshops}), do: %{data: Enum.map(workshops, &workshop/1)}

  def show(%{result: workshop}), do: %{data: workshop(workshop)}

  def console(%{result: console}) do
    %{
      data: %{
        workshop: workshop(console.workshop),
        batches: Enum.map(console.batches, &batch/1),
        pause: pause(console.pause),
        nextBatch: next_batch(console.next_batch),
        roster:
          Map.new(console.roster, fn {group, rows} -> {group, Enum.map(rows, &intake/1)} end),
        attention: console.attention
      }
    }
  end

  defp batch(batch) do
    %{
      number: batch.number,
      size: batch.size,
      sentAt: batch.sent_at,
      windowEndsAt: batch.window_ends_at
    }
  end

  defp pause(pause) do
    %{
      paused: pause.paused,
      pausedAt: pause.paused_at,
      pausedBy: pause.paused_by,
      resumedAt: pause.resumed_at,
      resumedBy: pause.resumed_by
    }
  end

  defp next_batch(next) do
    %{
      status: next.status,
      goesOutAt: next.goes_out_at,
      number: next.number,
      size: next.size,
      capacity: next.capacity,
      paid: next.paid,
      people:
        Enum.map(next.people, fn person ->
          %{
            firstName: person.first_name,
            lastName: person.last_name,
            minor: person.minor,
            queueDate: person.queue_date
          }
        end)
    }
  end

  defp intake(row) do
    %{
      id: row.id,
      state: row.state,
      origin: row.origin,
      batchNumber: row.batch_number,
      firstName: row.first_name,
      lastName: row.last_name,
      minor: row.minor,
      queueDate: row.queue_date,
      contactedAt: row.contacted_at
    }
  end

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
