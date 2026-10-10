defmodule DhcWeb.BeginnersWorkshopReportJSON do
  @moduledoc "Renders the Beginners' Workshop report (ALE-397)."

  def show(%{report: report}) do
    %{
      data: %{
        queue: queue(report.queue),
        twelveMonths: twelve_months(report.twelve_months),
        outcomes: Enum.map(report.outcomes, &outcome/1)
      }
    }
  end

  defp queue(queue) do
    %{
      waiting: queue.waiting,
      medianWaitDays: queue.median_wait_days,
      longestWaitDays: queue.longest_wait_days,
      medianDaysToSeat: queue.median_days_to_seat,
      workshopsToClear: queue.workshops_to_clear,
      removedInRetention: queue.removed_in_retention,
      invitable: queue.invitable,
      carriedFees: %{
        count: queue.carried_fees.count,
        totalPaidCents: queue.carried_fees.total_paid_cents,
        unlinked: queue.carried_fees.unlinked
      }
    }
  end

  defp twelve_months(totals) do
    %{
      workshops: totals.workshops,
      attended: totals.attended,
      joined: totals.joined,
      invitable: totals.invitable,
      invitedNotJoined: totals.invited_not_joined,
      averageAttendees: totals.average_attendees,
      conversionRate: totals.conversion_rate
    }
  end

  defp outcome(row) do
    %{
      workshopId: row.workshop_id,
      date: row.date,
      venue: row.venue,
      status: row.status,
      batchesSent: row.batches_sent,
      contacted: %{
        total: row.contacted.total,
        batch: row.contacted.batch,
        fastTrack: row.contacted.fast_track
      },
      exitsBeforePaying: row.exits_before_paying,
      paid: %{total: row.paid.total, carriedFee: row.paid.carried_fee},
      exitsAfterPaying: %{
        deferred: row.exits_after_paying.deferred,
        cancelledRefunded: row.exits_after_paying.cancelled_refunded,
        withdrawn: row.exits_after_paying.withdrawn,
        total: row.exits_after_paying.total,
        rate: row.exits_after_paying.rate
      },
      attendance: %{
        seated: row.attendance.seated,
        attended: row.attendance.attended,
        noShow: row.attendance.no_show,
        rate: row.attendance.rate
      },
      afterAttending: %{
        invitable: row.after_attending.invitable,
        invitedNotJoined: row.after_attending.invited_not_joined,
        joined: row.after_attending.joined
      },
      conversionRate: row.conversion_rate,
      groups: Enum.map(row.groups, &group/1)
    }
  end

  defp group(group) do
    %{
      kind: group.kind,
      number: group.number,
      windowEndsAt: group.window_ends_at,
      contacted: group.contacted,
      paidInWindow: group.paid_in_window,
      paidLater: group.paid_later,
      declined: group.declined,
      unpaidAtCutoff: group.unpaid_at_cutoff
    }
  end
end
