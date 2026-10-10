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
        roster: roster(console.roster),
        failedRefunds: Enum.map(console.failed_refunds, &failed_refund/1),
        unpaidAfterWindow: Enum.map(console.unpaid_after_window, &unpaid_after_window/1),
        unconfirmedCarriedFees:
          Enum.map(console.unconfirmed_carried_fees, &unconfirmed_carried_fee/1),
        attention: console.attention,
        fastTrackOpen: console.fast_track_open,
        fastTrackHoldersOnly: console.fast_track_holders_only,
        finalisation: console_finalisation(console.finalisation)
      }
    }
  end

  defp roster(roster) do
    %{
      seated: Enum.map(roster.seated, &intake/1),
      asked: Enum.map(roster.asked, &intake/1),
      attended: Enum.map(roster.attended, &intake/1),
      noShow: Enum.map(roster.no_show, &intake/1),
      out: Enum.map(roster.out, &intake/1)
    }
  end

  defp console_finalisation(nil), do: nil

  defp console_finalisation(finalisation),
    do: %{
      at: finalisation.at,
      by: finalisation.by,
      followUpAt: finalisation.follow_up_at,
      invitations: finalisation.invitations
    }

  @doc "The seat meter, shared with every workshop row."
  def seats(seats) do
    %{
      capacity: seats.capacity,
      paid: seats.paid,
      holds: seats.holds,
      free: seats.free,
      attended: seats.attended,
      noShow: seats.no_show
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
            queueDate: person.queue_date,
            confirms: person.confirms
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
      medical: row.medical,
      queueDate: row.queue_date,
      contactedAt: row.contacted_at,
      windowEndsAt: row.window_ends_at,
      holdExpiresAt: row.hold_expires_at,
      checkedInAt: row.checked_in_at,
      standing: row.standing,
      refund: row.refund && intake_refund(row.refund),
      linkGeneration: row.link_generation,
      emailLog:
        Enum.map(row.email_log, fn entry ->
          %{emailType: entry.email_type, at: entry.at, scheduled: entry.scheduled}
        end),
      history:
        Enum.map(row.history, fn entry ->
          %{
            command: entry.command,
            actor: entry.actor,
            occurredAt: entry.occurred_at,
            note: entry.note
          }
        end),
      availableCommands: row.available_commands,
      paidVia: row.paid_via,
      carriedFee: row.carried_fee
    }
  end

  defp unconfirmed_carried_fee(row) do
    %{
      id: row.id,
      firstName: row.first_name,
      lastName: row.last_name,
      batchNumber: row.batch_number,
      contactedAt: row.contacted_at
    }
  end

  defp unpaid_after_window(row) do
    %{
      id: row.id,
      firstName: row.first_name,
      lastName: row.last_name,
      batchNumber: row.batch_number,
      windowEndsAt: row.window_ends_at
    }
  end

  @doc "An Intake after a console Intake command (ALE-386)."
  def intake_command(%{result: intake}) do
    %{
      data: %{
        id: intake.id,
        state: intake.state,
        linkGeneration: intake.link_generation,
        outcome: intake.outcome
      }
    }
  end

  defp intake_refund(refund) do
    %{
      status: refund.status,
      method: refund.method,
      automatic: refund.automatic,
      amountCents: refund.amount_cents,
      currency: refund.currency
    }
  end

  defp failed_refund(refund) do
    %{
      id: refund.id,
      intakeId: refund.intake_id,
      firstName: refund.first_name,
      lastName: refund.last_name,
      amountCents: refund.amount_cents,
      currency: refund.currency,
      reason: refund.reason,
      failedAt: refund.failed_at
    }
  end

  @doc "A refund after Retry or Record manual refund (ALE-382)."
  def refund(%{result: refund}) do
    %{
      data: %{
        id: refund.id,
        intakeId: refund.intake_id,
        followsRefundId: refund.follows_refund_id,
        status: refund.status,
        method: refund.method,
        reason: refund.reason,
        amountCents: refund.amount_cents,
        currency: refund.currency,
        requestedAt: refund.requested_at,
        completedAt: refund.completed_at
      }
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
      seats: seats(view.seats),
      alerts: view.alerts,
      staff: staff(view.staff)
    }
  end

  @doc false
  def hh_mm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
end
