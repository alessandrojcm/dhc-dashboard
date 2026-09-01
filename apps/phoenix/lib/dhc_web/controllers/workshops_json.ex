defmodule DhcWeb.WorkshopsJSON do
  @moduledoc false

  alias Dhc.Workshops

  def render("calendar.json", %{workshops: workshops}) do
    %{data: %{workshops: Enum.map(workshops, &calendar_workshop/1)}}
  end

  def render("list.json", %{workshops: workshops}) do
    %{data: %{workshops: Enum.map(workshops, &workshop/1)}}
  end

  def render("management.json", %{workshop: workshop}) do
    %{data: %{workshop: calendar_workshop(workshop)}}
  end

  def render("precondition_failed.json", %{workshop: workshop}) do
    %{
      data: %{workshop: calendar_workshop(workshop)},
      errors: %{detail: "version precondition failed"}
    }
  end

  def render("registration_precondition_failed.json", %{registration: registration}) do
    %{
      data: %{registration: registration(registration)},
      errors: %{detail: "version precondition failed"}
    }
  end

  def render("interest.json", %{result: result}) do
    %{
      data: %{
        interested: result.interested,
        action: result.action,
        message: result.message
      }
    }
  end

  def render("registration_payment_intent.json", %{result: result}) do
    %{
      data: %{
        clientSecret: result.client_secret,
        paymentIntentId: result.payment_intent_id
      }
    }
  end

  def render("registration.json", %{registration: registration}) do
    %{data: %{registration: registration(registration)}}
  end

  def render("registration_cancelled.json", %{result: result}) do
    %{
      data: %{
        registration: registration(result.registration),
        refundPending: result.refund_pending
      }
    }
  end

  def render("external_registration_gate.json", %{gate: gate}) do
    data = %{canRegister: gate.can_register}

    data =
      if gate.can_register do
        Map.put(data, :workshop, external_registration_workshop(gate.workshop))
      else
        Map.put(data, :reason, gate.reason)
      end

    %{data: data}
  end

  def render("external_checkout_session.json", %{result: result}) do
    %{
      data: %{
        checkoutSessionId: result.checkout_session_id,
        checkoutClientSecret: result.checkout_client_secret,
        checkoutUrl: result.checkout_url
      }
    }
  end

  def render("attendance.json", %{registrations: registrations}) do
    %{data: %{registrations: Enum.map(registrations, &attendance_registration/1)}}
  end

  def render("refunds.json", %{refunds: refunds}) do
    %{data: %{refunds: Enum.map(refunds, &refund/1)}}
  end

  def render("refund.json", %{refund: refund}) do
    %{data: %{refund: refund(refund)}}
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
      lockVersion: Map.get(workshop, :lock_version),
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count,
      registrationCount: workshop.registration_count,
      placesRemaining: workshop.places_remaining,
      isAtCapacity: workshop.is_at_capacity
    }
  end

  defp external_registration_workshop(workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      startDate: workshop.start_date,
      endDate: workshop.end_date,
      location: workshop.location,
      priceNonMember: workshop.price_non_member,
      maxCapacity: workshop.max_capacity
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
      lockVersion: Map.get(workshop, :lock_version),
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count,
      registrationCount: workshop.registration_count,
      placesRemaining: workshop.places_remaining,
      isAtCapacity: workshop.is_at_capacity,
      currentUserInterest: workshop.current_user_interest,
      currentUserRegistration: registration(workshop.current_user_registration)
    }
  end

  defp registration(nil), do: nil

  defp registration(registration) do
    %{
      id: registration.id,
      status: registration.status,
      lockVersion: Map.get(registration, :lock_version)
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
      confirmedRegistrationCount: workshop.confirmed_registration_count,
      registrationCount: workshop.registration_count,
      placesRemaining: workshop.places_remaining,
      isAtCapacity: workshop.is_at_capacity
    }
  end

  defp attendee(attendee) do
    %{
      id: attendee.id,
      status: attendee.status,
      attendanceStatus: attendance_status(attendee.attendance_status),
      attendanceMarkedAt: attendee.attendance_marked_at,
      attendanceMarkedBy: attendee.attendance_marked_by,
      attendanceNotes: attendee.attendance_notes,
      amountPaid: attendee.amount_paid,
      currency: attendee.currency,
      registeredAt: attendee.registered_at,
      confirmedAt: attendee.confirmed_at,
      cancelledAt: attendee.cancelled_at,
      registrationNotes: attendee.registration_notes,
      lockVersion: Map.get(attendee, :lock_version),
      participant: participant(attendee.participant)
    }
  end

  defp attendance_registration(registration) do
    %{
      id: registration.id,
      attendanceStatus: attendance_status(registration.attendance_status),
      attendanceMarkedAt: registration.attendance_marked_at,
      attendanceMarkedBy: registration.attendance_marked_by,
      attendanceNotes: registration.attendance_notes,
      lockVersion: Map.get(registration, :lock_version)
    }
  end

  defp attendance_status("no_show"), do: "noShow"
  defp attendance_status(status), do: status

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
