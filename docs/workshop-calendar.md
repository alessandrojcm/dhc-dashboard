# Workshop Calendar integration

ALE-430 and ALE-432 publish regular Workshops and Beginners' Workshops to the
committee calendar through one synchronization protocol. ALE-433 adds private
Calendar Invitations for newly confirmed regular Workshop places. ALE-434 uses
that same participant protocol for Stripe-confirmed Beginners' Workshop places.
Workshop-credit confirmations, existing-attendee launch preview and reviewed
activation remain in the later ALE-429 tickets.
There is no Calendar administration screen.

## Deployment boundary

The migrations are additive: integration-owned event/control/recipient tables, no changes to Workshop
payment tables and no source foreign keys. Apply it before running the new code.
Deleted sources deliberately leave their Calendar removal obligations behind.

**Sending is inactive by default.** Credentials alone do not activate it. There
is intentionally no production activation environment variable or Mix command in
this first slice. ALE-437 owns the reviewed launch workflow. Do not enable the
internal `Dhc.WorkshopCalendar` `active` setting in production before that work,
the isolated-Google acceptance checks and separate authorization are complete.

The optional runtime credential names are:

- `WORKSHOP_CALENDAR_CLIENT_ID`
- `WORKSHOP_CALENDAR_CLIENT_SECRET`
- `WORKSHOP_CALENDAR_REFRESH_TOKEN`
- `WORKSHOP_CALENDAR_COMMITTEE_ID`
- `WORKSHOP_CALENDAR_PARTICIPANT_ID`

Provision them using the existing production secret-manager workflow, not checked
in configuration. Use a dedicated organizer owning **both** distinct calendars
and only `https://www.googleapis.com/auth/calendar.events.owned`. Calendar/ACL
administration and domain-wide delegation are not used. The integration does
not create calendars or manage sharing.

Share the committee calendar read-only with the Workspace committee group. Keep
the participant calendar restricted and unshared with that group. Review public
and inherited domain permissions separately: event guest-list flags are not a
calendar ACL. Google organizer/Workspace administrators retain privileged access.

## Beginners' Workshop end-time readiness

Beginners' Workshops require explicit Dublin civil `startTime` and `endTime`
when scheduled or rescheduled. The additive column migration accepts unknown
(`null`) legacy end times. The follow-up data migration uses the club-approved
baseline of **start + six Dublin civil hours** for existing missing values,
including historical rows. This is a baseline, not a recovered historical
duration. Explicitly recorded end times are never overwritten. Starts at or
after 18:00 remain unknown because six hours would cross midnight; overnight
sessions are unsupported. Rolling back the data migration preserves values
and any later coordinator corrections.

After deployment and before a later Beginners' Workshop Calendar launch, run
`mix dhc.beginners_workshops.end_times` (read-only, no Google calls). Inspect
`Dhc.BeginnersWorkshops.end_time_report/1` in an authorized operator session,
then resolve each remaining upcoming row with the authorized
`{:backfill_end_time, workshop_id, %{end_time: "HH:MM"}}` command through
`Dhc.BeginnersWorkshops.execute/3`. Backfill changes no cutoff, offer-round,
email, or attendance policy. While sending is active, backfill records Calendar
intent just like scheduling and rescheduling; it never calls Google inline.

The separate Intake Email data migration adds an `endTime` chip to the six
schedule-bearing templates, retaining coordinator copy and existing chips.
If there is no start-time chip, it appends an end-time sentence instead. It
rechecks the shared 2,000-character worst-case measure before saving: a custom
body too close to the limit stops the deployment with its email type and
required size, rather than truncating copy or breaking email delivery. Shorten
that template in the existing editor and rerun the migration. Rollback keeps
the edited bodies; queued emails are not rewritten or resent. Remaining
unknown workshop ends render as `TBC`.

## Ownership and recovery

Workshop operations commit identifier-only synchronization intent alongside the
source change. Google runs outside those transactions. The source-owned
`Dhc.Workshops.calendar_projection/1` and
`Dhc.BeginnersWorkshops.calendar_projection/1` exclude descriptions, participant
details, prices and notes. Source kind plus immutable ID distinguish the two
contexts even if their IDs match. Calendar content consists of title/status, time, venue and an
ordinary authenticated dashboard URL. Committee events have no guests and all
mutations use `sendUpdates=none`. Beginners' Workshops appear on scheduling,
independent of offers or payments, using the protected workshop Manage URL.
Their owner converts both Dublin civil times through Club Calendar. An unknown
or invalid legacy end never becomes a guessed duration or a malformed Google
event: it is reported without contacting Google. A source schedule correction
re-arms only this data failure, not a terminal Google/authorization failure.

The worker and five-minute repair pass share `Dhc.WorkshopCalendar.sync/3`.
Event identities and recreation generations are persisted before creation;
uncertain success is recovered by reading the same organizer event. Updates and
deletions use Google ETags. An event lease and source revision fence local
acknowledgments. Interrupted ownership expires after two minutes. Repair also
finds deleted-source work and missed wake-ups.

A persisted create checkpoint distinguishes an event never requested from an
insert that may still arrive after timeout. Never-requested deletions settle
locally. A 404 after a prepared create stays in repair until a tombstone or
successful delete proves that a late insert cannot leave a live event behind.

Temporary failures back off from 30 seconds and exhaust after six attempts.
Permanent/exhausted failures retain their reason and episode and notify active
holders of `workshops.manage` for regular Workshops or
`beginners.workshops.alerts.receive` for Beginners' Workshops. Beginners' Workshop
alert wording stays with its Notification copy owner. The episode's alert marker survives Notification
retention. Repair does not repeatedly call Google for terminal failures. The
operator-facing recovery tooling belongs to ALE-437; do not delete integration
rows to retry, because that discards identity and cleanup obligations.

`Dhc.WorkshopCalendar.pause/0` is an internal, durable stop for new mutations.
`resume/0` clears it and queues current facts, but cannot activate an inactive
installation. Explicit resume also re-arms failed work with a bounded attempt
budget after the operator repairs authorization/configuration; an unchanged
failure keeps its existing alert episode rather than sending another alert.
A request already in flight cannot be recalled. Jobs and deletion
obligations survive pause. Domain commands remain available with missing Google
credentials, while inactive, or while paused.

Archival does not change Calendar. Cancellation retains the committee event at
its scheduled time, marked Cancelled. Hard deletion removes the organizer event,
including after its end. First publication, detail repair and missing-event
recreation stop at the exact event end; owed cancellation/deletion still runs.
Early Beginners' Workshop attendance finalisation does not cancel, remove or
shorten its committee event; its scheduled end remains the publication cutoff.

## Participant invitations and address repair

Regular Workshop payment completion captures the saved Registration address in
the same transaction that confirms the new place. Member addresses come from the
member snapshot, not PaymentIntent receipt/payer details. External addresses are
the participant details saved on the Registration; the legacy Checkout
`customer_email` fallback still supports booking identity but never fills a
missing participant snapshot or Calendar address. Pending Registrations,
unfinished Checkout and compensating payments do not qualify. Replayed payment
completion never captures another entitlement or selects a newer profile address.

Beginners' Workshop Stripe completion captures the locked Waitlist entry's
recorded address only when the Intake actually becomes paid. The retained
binding belongs to the integration, keyed by the Intake's immutable ID; neither
the Intake nor a delayed worker keeps/chooses another email snapshot. The
Checkout payer, frozen hold email and Guardian are not recipient sources. Return
and webhook duplicates leave that binding unchanged. Offers, open holds, failed
or unpaid Checkout, policy failures and payments refunded after the place closed
do not create invitation entitlements. Google failures cannot undo confirmation.

Beginners' Workshop Settlement rows record `:remove_calendar_place` for deferral,
withdrawal, cancel-with-refund and workshop cancellation alongside their existing
effects. Refund submission/completion is independent. Attendance finalisation and
corrections deliberately have no removal step, even when a no-show is corrected
to deferred: that is attendance history, not a prospective place withdrawal.
`calendar_place_ids/1` therefore reports confirmation facts (`paid_at`), including
historical Intakes; a retained binding's explicit removal obligation determines
place loss. This read never selects recipients or creates new entitlements.
Reschedule uses the same participant event, preserving surviving Google RSVPs.
Recipient failures use the Beginners' Workshop alert capability and its
Notification copy owner, with one durable episode per failed place.

The integration retains each logical place and its selected address separately
from source storage, including failed addresses and owed removals. The shared
`sync/3` operation takes `audience: :participant`; identifier-only jobs include
that audience. Event identity/generation, leases, retries and failure episodes
are the same protocol as committee synchronization. Participant events have an
independent identity on the restricted calendar and contain only title, explicit
start/end and venue, plus Google event/guest metadata. Guests cannot see other
guests, edit the event or invite others. No dashboard links or descriptions are
exported.

Cancellation and refund requests record removal when the place ends, not when
Stripe completes its refund. Whole-workshop cancellation deletes the participant
event while retaining the Cancelled committee entry. Reconciliation reads Google
before replacing the attendee array and preserves surviving guest records/RSVPs.
Removals run before isolated additions; malformed or Google-rejected addresses
remain per-place follow-up and cannot block valid invitations. They notify active
Workshop managers once per durable failure episode. No-op reconciliation is
silent; privacy-only repair does not notify guests. New invitations, meaningful
detail changes, guest removals and event cancellation use `sendUpdates=all`.

Attendance and archival preserve Calendar history. At/after the scheduled end,
there are no first invitations, detail rewrites or missing-event recreations.
Owed attendee removals and event cancellation still run. A Google-only RSVP
decline or removal of a personal copy is not a lost dashboard place or another
invitation entitlement. A new confirmed Registration after cancellation is a new
entitlement, including when cancellation and rebooking happened while paused.

Address repair is a deliberate operator operation, not a coordinator screen:

1. Verify the participant and the corrected address using the club's ordinary
   manual email-change process. Use an authorized release console; do not put
   addresses or credentials in job arguments, logs or shell history.
2. Call `Dhc.WorkshopCalendar.pause/0`. Wait for any in-flight request to finish;
   pause cannot recall an HTTP request already sent.
3. Call `Dhc.WorkshopCalendar.correct_recipient(:workshop, workshop_id,
   registration_id, corrected_address)`. It refuses an unpaused integration,
   invalid address, missing/inactive binding or a still-live event lease
    (`:busy`; let it finish/expire rather than deleting integration rows).
   For a Beginners' Workshop use `:beginners_workshop`, its workshop ID and
   Intake ID with the same operation and preconditions.
4. Call `Dhc.WorkshopCalendar.resume/0`. The same reconciliation operation
   removes the old organizer guest and uses the corrected retained address for
   the invitation. The old address remains a removal obligation; ordinary profile
   edits and a Google-only repair cannot silently replace this binding. A repair
   after event end removes the old guest but does not send a first invitation to
   the new address.
5. Verify the organizer event after reconciliation. Do not promise email delivery
   or erasure of recipient-held copies. A failed repair follows the ordinary
   keyed-notification/manual-follow-up path; it never changes a booking.

This operation neither activates sending nor changes the participant's profile,
Registration snapshot or Intake. Person hard-delete privacy cleanup is ALE-436; do not
treat place cancellation or attendance history as that cleanup.

## Verification

Automated tests substitute Google and OAuth HTTP only through Req.Test; they
must never reach live Google. The ordinary Phoenix Testcontainers harness is
required for source/job/recovery/concurrency tests:

```sh
cd apps/phoenix
mise exec -- mix test test/dhc/workshop_calendar test/dhc/workshops/calendar_projection_test.exs
mise exec -- mix precommit
```

Before production activation, isolated calendars must demonstrate committee
read-only access, no guest/roster exposure, event creation/update/cancellation,
Google-side repair and OAuth revocation handling. Later participant slices must
also demonstrate guest privacy, external invitations and RSVP preservation.
API success means Google accepted a projection, not that an email was delivered.
External calendar copies, delivered invitations and Google's retained data cannot
be guaranteed erased.
