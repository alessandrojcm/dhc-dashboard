# Workshop Calendar and Calendar Invitations

Status: finalized by user confirmation on 2026-11-03.
Implementation and Google configuration changes remain a separate step; this
design sign-off does not authorize them.

Research: [Google Calendar workshop sync](research/google-calendar-workshop-sync.md).
Domain terms: Workshop Calendar and Calendar Invitation in [CONTEXT.md](../CONTEXT.md).

## Agreed decisions

Confirmed in interview round 1:

- The committee views a shared Workshop Calendar for awareness. Committee members
  are observers, not guests asked to RSVP to every event.
- Workshops appear when scheduled, independently of the first payment. The
  regular Workshop planned/published distinction is detailed below.
- The dashboard owns workshop details. Google Calendar edits do not reschedule
  a workshop in the dashboard.
- Declining a Calendar Invitation does not cancel a place or request a refund.
- Calendar Invitations supplement existing confirmation and workshop emails.
- Launch includes upcoming workshops and eligible existing attendees through an
  explicit invitation-sending launch step. Past workshops are excluded.

Confirmed in interview round 2:

- A Calendar Invitation follows a confirmed place: a confirmed regular Workshop
  Registration or a paid Beginners' Workshop Intake, whether paid through Stripe
  or confirmed using a Carried Fee. Contact, pending payment, and checkout alone
  do not qualify.
- Losing a place removes its Calendar Invitation without waiting for the refund
  to complete. Deferral, withdrawal and cancellation follow this rule. Cancelling
  a workshop cancels its attendee event. Attendance/no-show recording preserves
  past calendar events rather than removing people from history.
- Beginners' Workshops gain an explicit end time per workshop. Upcoming existing
  workshops need their end times filled before launch; there is no guessed duration.
- A Google Workspace committee group controls committee calendar access. The club
  administrator manages that group; this feature does not synchronize dashboard roles.
- Committee readers see workshop details (title, time, venue and a dashboard link),
  not participant names or email addresses. Calendar visibility is not dashboard
  roster authorization. Guests must also be unable to see one another's details.
- A regular Workshop appears while planned, clearly marked Planned. Publication
  updates the same committee event. A Beginners' Workshop appears when scheduled.
- Published regular Workshops remain subject to their existing edit restrictions.
  Adding regular Workshop rescheduling is separate work. This integration mirrors
  changes the dashboard already permits.

Confirmed in interview round 3:

- Committee events contain title, planned/published status, time, venue and a
  protected dashboard link. Participant events contain only title, time and venue;
  no joining instructions. Neither contains payment details, medical information,
  internal notes or personal access tokens.
- Invitations go to the participant's recorded email when their place is confirmed,
  never the payer or Guardian. Retain the invited address; later profile email
  changes do not silently move an invitation.
- Google delivery is asynchronous and cannot undo a successful payment or release
  a confirmed place. Retry temporary failures and surface persistent failures to
  the relevant coordinator.
- Keep a cancelled committee event at its original time, marked Cancelled.
  Cancel the participant event and its invitations instead of retaining it as an
  active event.
- Repair Google-side changes to dashboard-owned details and recreate missing
  organizer events. Preserve guest RSVPs; guest declines or removal of their own
  calendar copies do not cause repeated invitations.
- Archival alone leaves Calendar unchanged. Workshop cancellation cancels the
  participant event; hard deletion of a workshop with no registrations removes
  its committee entry.
- Send invitations, meaningful participant-facing updates, and cancellations.
  Reconciliation does not resend unchanged events, and internal-only changes do
  not trigger attendee emails. Committee members do not receive event invitations.
  Google's API controls exact notification delivery behavior.

Confirmed in interview round 4:

- Use a dedicated club organizer owning two calendars: a committee-only calendar
  shared read-only with the Workspace committee group, and a restricted participant
  calendar carrying Calendar Invitations. Participant rosters never go onto the
  committee calendar.
- Use organizer-account OAuth with a securely stored refresh token and event-only
  access, rather than Workspace domain-wide delegation. With the organizer owning
  both calendars, use `calendar.events.owned`; the app does not manage calendar ACLs.
- Beginners' Workshop start and end are on the same Dublin civil date, with end
  after start. Scheduling/rescheduling explicitly specifies both; there is no
  automatic end-time guess.
- Preserve historical event details, but remove a hard-deleted person's attendee
  details from organizer-owned events. Recipient/Google copies cannot be guaranteed
  erased by this integration.
- Do not send first invitations or automatically recreate organizer events after
  the event ends. Still complete outstanding cancellations, removals and privacy
  cleanup.
- Test using isolated calendars, then preview upcoming events, recipients and
  missing data before explicit production activation. Launch includes existing
  eligible attendees. A pause switch stops outbound changes without deleting
  events; resume reconciles current facts rather than replaying stale invitations.

Confirmed after clarification of Q24 and Q25:

- Email changes are already a manual club operation. Correcting an existing
  Calendar Invitation is also handled manually; no calendar-specific address
  editor, coordinator correction button, or automatic address migration is in scope.
- Use automatic retries and notify the relevant coordinator when intervention
  is needed. No separate calendar-management screen, per-workshop status UI or
  coordinator retry button is required for v1. An invalid recipient must not block
  invitations to other eligible people.

Confirmed for existing attendees at launch (Q29):

- Use the saved Registration email for regular Workshops and the person's current
  recorded email for existing Beginners' Workshop places. Retain the invited
  address after sending. Missing/invalid addresses require manual follow-up
  without blocking invitations to other people.

## Sign-off and implementation boundary

The user confirmed the complete design summary. No interview policy questions
remain open. Google account, calendar IDs, credentials, and production activation
remain provisioning work, not facts established by this document.

## Consequences of the agreed rules

- A new confirmed place after an earlier cancellation qualifies for an invitation
  again. This differs from a guest's Google-only RSVP decline, which does not
  change their place and must not cause a fresh invitation.
- Sync success means Google's event state was updated, not that an invitation
  email was delivered or accepted.
- Manual calendar-address repairs must be coordinated with retained integration
  state so reconciliation does not restore the obsolete address.

## Verified Google constraints

- Google defines `guestsCanSeeOtherGuests` for attendees other than the organizer;
  it is not an access-control boundary for people reading the organizer calendar.
  Separate committee events without attendees from attendee-bearing events on a
  restricted calendar to enforce the agreed audiences. See the
  [Events resource](https://developers.google.com/workspace/calendar/api/v3/reference/events#guestsCanSeeOtherGuests).
- An organizer owning both target calendars can use the event-only
  `calendar.events.owned` scope; a calendar merely shared to that organizer needs
  `calendar.events`. Calendar and ACL administration need not be granted to the
  application. See [Calendar authorization scopes](https://developers.google.com/workspace/calendar/api/auth).
- Workspace domain-wide delegation authorizes scopes for a client across the
  domain. The application chooses an impersonated user; the documented grant
  is not a one-organizer-user restriction. Organizer-account OAuth is the
  alternative when that broader trust is unnecessary. See
  [delegation and impersonation](https://developers.google.com/identity/protocols/oauth2/service-account#delegatingauthority).
