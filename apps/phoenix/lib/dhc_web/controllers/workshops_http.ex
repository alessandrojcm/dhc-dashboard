defmodule DhcWeb.WorkshopsHTTP do
  @moduledoc """
  The problem fallback for the Workshops HTTP slice.

  `DhcWeb.WorkshopsController` renames the few domain atoms whose wording
  differs by flow (an external Checkout Session versus a member
  PaymentIntent, a refund request versus a Workshop cancellation); renamed
  reasons keep the domain atom as their public code.
  """

  use DhcWeb.Problem,
    reasons: %{
      # ── 404 ──────────────────────────────────────────────────────
      not_found: {404, "Workshop not found"},
      registration_not_found: {404, "Workshop not found"},
      checkout_session_not_found: {404, "Checkout session not found"},

      # ── 409 ──────────────────────────────────────────────────────
      already_archived: {409, "Workshop is already archived"},
      already_registered: {409, "Already registered for this workshop"},
      email_already_registered:
        {409, "This email is already registered for this workshop", :already_registered},
      full: {409, "Workshop is full"},
      compensation_pending: {409, "Payment accepted; refund is pending"},
      # Workshop cancellation found a registration whose refund is already
      # requested (ALE-340).
      already_requested: {409, "A refund has already been requested for a registration"},

      # ── 422 lifecycle ────────────────────────────────────────────
      not_editable: {422, "Only planned workshops can be edited"},
      pricing_locked: {422, "Cannot change pricing when there are active registrations"},
      not_publishable: {422, "Only planned workshops can be published"},
      not_cancellable: {422, "Only published workshops can be cancelled"},
      not_planned: {422, "Can only express interest in planned workshops"},

      # ── 422 registration and payment ─────────────────────────────
      not_published: {422, "Workshop not available for registration"},
      invalid_amount: {422, "Amount must be positive"},
      payment_not_completed: {422, "Payment not completed"},
      payment_metadata_mismatch: {422, "Payment intent does not match workshop registration"},
      checkout_metadata_mismatch:
        {422, "Checkout session does not match workshop registration", :payment_metadata_mismatch},
      invalid_return_url: {422, "Return URL must include the Checkout Session placeholder"},
      customer_details_missing: {422, "Checkout session is missing attendee details"},
      payment_intent_required: {422, "Payment intent ID required"},
      checkout_details_required: {422, "Payment attempt ID and return URL are required"},
      checkout_session_required: {422, "Checkout session ID required"},

      # ── 422 refunds ──────────────────────────────────────────────
      refund_reason_required: {422, "Refund reason is required"},
      already_refunded: {422, "Registration already refunded"},
      workshop_finished: {422, "Cannot refund finished workshop"},
      not_paid: {422, "Registration has no payment to refund"},
      deadline_passed: {422, "Refund deadline has passed"},
      refund_already_requested:
        {422, "Refund already requested for this registration", :already_requested},

      # ── 422 attendance ───────────────────────────────────────────
      not_started: {422, "Cannot update attendance before the Workshop has started"},
      invalid_attendee: {422, "Attendance updates must target active Workshop attendees"},
      invalid_updates: {422, "Invalid attendance updates"},
      attendance_updates_required: {422, "Attendance updates are required"},

      # ── 502 ──────────────────────────────────────────────────────
      payment_failed: {502, "Payment provider request failed"},
      refund_failed: {502, "Refund provider request failed"}
    },
    fields: %{
      start_date: "startDate",
      end_date: "endDate",
      max_capacity: "maxCapacity",
      price_member: "priceMember",
      price_non_member: "priceNonMember",
      is_public: "isPublic",
      refund_days: "refundDays",
      announce_discord: "announceDiscord",
      announce_email: "announceEmail"
    }
end
