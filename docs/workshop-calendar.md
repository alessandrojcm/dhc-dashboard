# Workshop Calendar integration

ALE-430 implements regular Workshops on the committee calendar. Participant
invitations, Beginners' Workshops, launch preview and reviewed activation remain
in the later ALE-429 tickets. There is no Calendar administration screen.

## Deployment boundary

The migration is additive: two integration-owned tables, no changes to Workshop
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
when scheduled or rescheduled. Existing rows retain an unknown (`null`) end
time; do not infer a duration. Before a later Beginners' Workshop Calendar
launch, inspect `Dhc.BeginnersWorkshops.end_time_report/1` in an authorized
operator session, then backfill each upcoming row with the authorized
`{:backfill_end_time, workshop_id, %{end_time: "HH:MM"}}` command through
`Dhc.BeginnersWorkshops.execute/3`. Backfill changes no cutoff, offer-round,
email, or attendance policy, and this slice makes no Google mutation.

## Ownership and recovery

Workshop operations commit identifier-only synchronization intent alongside the
source change. Google runs outside those transactions. The source-owned
`Dhc.Workshops.calendar_projection/1` excludes descriptions, participant details,
prices and notes. Calendar content consists of title/status, time, venue and an
ordinary authenticated dashboard URL. Committee events have no guests and all
mutations use `sendUpdates=none`.

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
holders of `workshops.manage`. The episode's alert marker survives Notification
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
