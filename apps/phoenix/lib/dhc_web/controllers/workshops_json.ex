defmodule DhcWeb.WorkshopsJSON do
  @moduledoc false

  alias Dhc.Workshops

  def render("calendar.json", %{workshops: workshops}) do
    %{data: %{workshops: Enum.map(workshops, &calendar_workshop/1)}}
  end

  def render("list.json", %{workshops: workshops}) do
    %{data: %{workshops: Enum.map(workshops, &workshop/1)}}
  end

  @doc """
  GET /workshops/{id}/attendees — combined coordinator management payload.

  Renders Workshop vocabulary with camelCase fields and a normalized
  `participant` DTO (`type` `member` | `external`, `displayName`, `email`)
  instead of the `user_profiles` / `external_users` storage join shapes.
  """
  def render("attendees.json", %{workshop: workshop, attendees: attendees, refunds: refunds}) do
    %{
      data: %{
        workshop: workshop_summary(workshop),
        attendees: Enum.map(attendees, &attendee/1),
        refunds: Enum.map(refunds, &refund/1)
      }
    }
  end

  defp calendar_workshop(workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      location: workshop.location,
      startDate: workshop.start_date,
      endDate: workshop.end_date,
      maxCapacity: workshop.max_capacity,
      priceMember: workshop.price_member,
      priceNonMember: workshop.price_non_member,
      isPublic: workshop.is_public,
      refundDays: workshop.refund_days,
      status: workshop.status,
      announceDiscord: workshop.announce_discord,
      announceEmail: workshop.announce_email,
      createdBy: workshop.created_by,
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count
    }
  end

  defp workshop(workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      location: workshop.location,
      startDate: workshop.start_date,
      endDate: workshop.end_date,
      maxCapacity: workshop.max_capacity,
      priceMember: workshop.price_member,
      priceNonMember: workshop.price_non_member,
      isPublic: workshop.is_public,
      refundDays: workshop.refund_days,
      status: workshop.status,
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count,
      currentUserInterest: workshop.current_user_interest,
      currentUserRegistration: registration(workshop.current_user_registration)
    }
  end

  defp registration(nil), do: nil

  defp registration(registration) do
    %{
      id: registration.id,
      status: registration.status
    }
  end

  defp workshop_summary(workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      location: workshop.location,
      startDate: workshop.start_date,
      endDate: workshop.end_date,
      maxCapacity: workshop.max_capacity,
      priceMember: workshop.price_member,
      priceNonMember: workshop.price_non_member,
      isPublic: workshop.is_public,
      refundDays: workshop.refund_days,
      status: workshop.status,
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count
    }
  end

  defp attendee(attendee) do
    %{
      id: attendee.id,
      status: attendee.status,
      attendanceStatus: attendee.attendance_status,
      attendanceMarkedAt: attendee.attendance_marked_at,
      attendanceMarkedBy: attendee.attendance_marked_by,
      attendanceNotes: attendee.attendance_notes,
      amountPaid: attendee.amount_paid,
      currency: attendee.currency,
      registeredAt: attendee.registered_at,
      confirmedAt: attendee.confirmed_at,
      cancelledAt: attendee.cancelled_at,
      registrationNotes: attendee.registration_notes,
      participant: participant(attendee.participant)
    }
  end

  defp refund(refund) do
    %{
      id: refund.id,
      registrationId: refund.registration_id,
      refundAmount: refund.refund_amount,
      refundReason: refund.refund_reason,
      status: refund.status,
      stripeRefundId: refund.stripe_refund_id,
      requestedAt: refund.requested_at,
      processedAt: refund.processed_at,
      completedAt: refund.completed_at,
      participant: participant(refund.participant)
    }
  end

  defp participant(%{type: type, display_name: display_name, email: email}) do
    %{type: type, displayName: display_name, email: email}
  end

  # Expose the canonical coordinator management roles so controllers/tests can
  # reference the same source of truth as the context (see Dhc.Workshops).
  defdelegate coordinator_management_roles, to: Workshops
end
