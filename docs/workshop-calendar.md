# Workshop Calendar integration

ALE-430 and ALE-432 publish regular Workshops and Beginners' Workshops to the
committee calendar through one synchronization protocol. ALE-433 adds private
Calendar Invitations for newly confirmed regular Workshop places. ALE-434 and
ALE-435 use that same participant protocol for Stripe-paid and workshop-credit
Beginners' Workshop places. ALE-437 adds a read-only launch preview and explicit
activation for existing upcoming eligible attendees.
There is no Calendar administration screen.

## Deployment boundary

The integration owns its event/control/recipient tables, with no changes to Workshop
payment tables and no source foreign keys. ALE-437 replaces the old pause flag
with target-bound activation fields. Apply migrations before running the new code.
Deleted sources deliberately leave their Calendar removal obligations behind.

**Sending is inactive by default.** Credentials and deployment alone do not
activate it. Set `WORKSHOP_CALENDAR_ENVIRONMENT` to `isolated` or `production`,
then explicitly run the matching activation task after review. The durable
activation key binds that environment, both calendar IDs, and the OAuth client
ID; changing any of them returns sending to inactive until another explicit
activation.

The optional runtime credential names are:

- `WORKSHOP_CALENDAR_CLIENT_ID`
- `WORKSHOP_CALENDAR_CLIENT_SECRET`
- `WORKSHOP_CALENDAR_REFRESH_TOKEN`
- `WORKSHOP_CALENDAR_COMMITTEE_ID`
- `WORKSHOP_CALENDAR_PARTICIPANT_ID`

`isolated` requires separate credentials and calendars with synthetic data. It
is not a production-data sanitizer. Production credentials, resources, and
Google acceptance checks are outside this implementation.

Run these only in an authorized operator session:

```sh
cd apps/phoenix
mix dhc.workshop_calendar.preview
mix dhc.workshop_calendar.activate isolated
mix dhc.workshop_calendar.activate production
```

Preview starts only its read dependencies and Repo, not the application or its
workers. It emits private JSON containing recipient PII and makes no Google,
database or job writes. Activation re-reads and locks the current sources; it
never accepts a saved preview as input. Required missing or invalid end/schedule data refuses the
entire activation atomically. Missing or invalid recipients remain per-place
follow-up and do not stop eligible recipients from being activated.

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

## Reviewed destination backfill (ALE-443)

Existing upcoming regular Workshops can be enriched with manual destinations
from a one-off, human-reviewed mapping of short venue labels. A mapping entry
asserts that the label and the destination are the same physical Venue; list a
label under `ambiguous` (or leave it out) when it is not certain. The mapping
accepts only `destination_name`, `destination_address` and `directions_url`: no
Places search, provider identity or first-result choice, and it is not a
reusable venue registry. Google-selected destinations are not accepted until
the terms-supported selection implementation exists.

Run these only in an authorized operator session:

```sh
cd apps/phoenix
mix dhc.destination_backfill.preview MAPPING.json > preview.json
# Review every row, then write PLAN.json with the preview's "mapping" and an
# "approved_targets" list copied from the reviewed "proposed_targets".
mix dhc.destination_backfill.apply PLAN.json --operator PRINCIPAL_ID
```

Preview starts only its read dependencies and Repo, never the application or
its workers, and makes no Google, database or job writes. It lists every
Workshop that has not ended with its label, status, Dublin schedule, current
and proposed destination, outcome (`change`, `unchanged`, or `refused` with a
reason such as `unreviewed_venue`, `ambiguous_venue`, `destination_conflict`,
`cancelled`, `archived` or `started`) and Calendar effect. It contains no
recipient addresses.

Apply requires a principal holding `workshops.manage`. Each approved target is
re-read under the Workshop lock against the facts the reviewer saw: a changed
label, Dublin schedule, status or destination, a cancellation, archival or
deletion, or a start at or before the clock reading taken under the lock is
refused and reported, never overwritten. The proposed destination always
comes from the mapping for the target's label. Accepted targets change only
the three destination fields and record Calendar intent in the same
transaction; repeating an applied plan writes nothing. Workshops that would now
change but were not approved are reported as `discovered` and left alone.

Enrichment is an ordinary meaningful Calendar change: inactive sending keeps
the intent without Google calls, and active sending updates the existing
events (retained recipients and RSVPs, `sendUpdates=all` for participants, so
Google may email attendees). No workshop email is queued and no template
changes. The event-end detail cutoff still applies. No production backfill has
been authorized or run.

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
Permanent or exhausted event failures retain their reason and episode and report
to Sentry. An episode is claimed under lock; best-effort capture follows commit,
never an uncommitted synchronization transaction. Sentry is monitoring, not a
guaranteed delivery ledger. Repair does not repeatedly call Google for terminal
failures; do not delete integration rows to retry, because that discards identity and cleanup
obligations. There is no pause/resume or manual recovery command. Domain commands
remain available with missing Google credentials or inactive sending.

Archival does not change Calendar. Cancellation retains the committee event at
its scheduled time, marked Cancelled; a cancelled source that was never published
does not acquire a new event at launch. Hard deletion removes the organizer event,
including after its end. First publication, detail repair and missing-event
recreation stop at the exact event end; owed cancellation/deletion still runs.
Early Beginners' Workshop attendance finalisation does not cancel, remove or
shorten its committee event; its scheduled end remains the publication cutoff.

## Participant invitations

Regular Workshop payment completion captures the saved Registration address in
the same transaction that confirms the new place. Member addresses come from the
member snapshot, not PaymentIntent receipt/payer details. External addresses are
the participant details saved on the Registration; the legacy Checkout
`customer_email` fallback still supports booking identity but never fills a
missing participant snapshot or Calendar address. Pending Registrations,
unfinished Checkout and compensating payments do not qualify. Replayed payment
completion never captures another entitlement or selects a newer profile address.

Beginners' Workshop Stripe completion and workshop-credit confirmation capture
the locked Waitlist entry's recorded address only when the Intake actually
becomes paid. The person's Intake-link confirmation and the coordinator's
confirmation use the same command; it records the binding after applying the
credit in that transaction. Held credit and contacted places alone do not qualify,
and refused or repeated confirmations record no new entitlement. The retained
binding belongs to the integration, keyed by the Intake's immutable ID; neither
the Intake nor a delayed worker keeps/chooses another email snapshot. The
Checkout payer, frozen hold email and Guardian are not recipient sources.
Payment replays and repeated credit confirmations leave that binding unchanged.
Offers, open holds, failed or unpaid Checkout, policy failures and payments
refunded after the place closed do not create invitation entitlements. Google
failures cannot undo confirmation.

Beginners' Workshop Settlement rows record `:remove_calendar_place` for deferral,
withdrawal, cancel-with-refund and workshop cancellation alongside their existing
effects. Refund submission/completion is independent. Attendance finalisation and
corrections deliberately have no removal step, even when a no-show is corrected
to deferred: that is attendance history, not a prospective place withdrawal.
`calendar_place_ids/1` therefore reports confirmation facts (`paid_at`), including
historical Intakes; a retained binding's explicit removal obligation determines
place loss. This read never selects recipients or creates new entitlements.
Reschedule uses the same participant event, preserving surviving Google RSVPs.
Recipient failures retain one durable episode per failed place and report to
Sentry; they do not create capability/dashboard Notifications.

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
remain per-place follow-up and cannot block valid invitations. Terminal recipient
failures report to Sentry once per durable failure episode. No-op reconciliation is
silent; privacy-only repair does not notify guests. New invitations, meaningful
detail changes, guest removals and event cancellation use `sendUpdates=all`.

Attendance and archival preserve Calendar history. At/after the scheduled end,
there are no first invitations, detail rewrites or missing-event recreations.
Owed attendee removals and event cancellation still run. A Google-only RSVP
decline or removal of a personal copy is not a lost dashboard place or another
invitation entitlement. A new confirmed Registration or Intake after a lost place
is a new entitlement, including when loss and reconfirmation happened while sending was inactive.
Spending or forfeiting an applied workshop credit during attendance finalisation
does not remove historical invitations.

## Person deletion and historical privacy cleanup (ALE-436)

The existing Beginners' Workshop manual Delete and three-month retention purge
capture privacy-removal obligations for every retained Intake binding before
anonymising or unlinking the person. They use the same authoritative transaction
and locks as before. Authorization, deletion refusals, refunds, anonymisation and
reporting are unchanged; Google never runs in that transaction and cannot delay
the person's deletion. There is no new Member/Principal deletion policy: those
records currently have no supported person hard-delete entrypoint. The shared
Calendar boundary accepts source-owned place identifiers for either source kind
when a supported operation needs it; it never finds people by matching email.

Obligations live on the integration's retained recipient rows, without source
foreign keys. Identifier-only jobs and periodic repair find them even after the
Waitlist entry/profile is gone. Inactive sending retains them without Google
mutations; activation reconciles current facts, not queued attendee snapshots.
Cleanup runs at and after event end, and even with an unknown legacy end time.
It removes the retained selected address from current and
historical organizer events, preserving other guests, their RSVPs and event
details. An address shared by another active entitlement remains that guest's
address; deleting one binding must not cancel the other's invitation.

Cleanup uses the event lease/revision and Google's conditional-write ETag. Even
when the guest is already absent, a conditional write advances the provider fence
before personal data is discarded, preventing an expired worker's late update
from restoring it. Ambiguous success is read back through the same bounded retry
and Sentry-reporting protocol. A tombstone or an event never requested can
settle without creation. A bare 404 after a prepared creation retains the
obligation: the uncertain insertion might still arrive. Cleanup never recreates
an event solely to remove someone, including after its end.

Once acknowledged under current ownership, cleanup clears the binding's selected
address, previous addresses and recipient failure data. It keeps only an inactive,
address-free place tombstone so stale confirmation retries cannot select an
address again. Event acknowledgments contain no attendee snapshots; jobs contain
no addresses or request bodies. A failed historical removal remains outstanding
for bounded reconciliation and Sentry reporting.

This cleans integration-owned organizer details only. It cannot guarantee erasure
of recipient calendar copies, delivered invitation emails or Google's retained
data. Neither successful HTTP responses nor cleanup acknowledgments promise
invitation email delivery or universal deletion.

## Verification

Automated tests substitute Google and OAuth HTTP only through Req.Test; they
must never reach live Google. The ordinary Phoenix Testcontainers harness is
required for source/job/recovery/concurrency tests:

```sh
cd apps/phoenix
mise exec -- mix test test/dhc/workshop_calendar test/dhc/workshops/calendar_projection_test.exs
mise exec -- mix precommit
```

Tests stub Google and OAuth with Req.Test; they do not claim live-Google,
isolated-calendar, or production acceptance coverage. When real isolated checks
are separately authorized, use separate credentials/calendars and synthetic data.
API success means Google accepted a projection, not that an email was delivered.
External calendar copies, delivered invitations and Google's retained data cannot
be guaranteed erased.
