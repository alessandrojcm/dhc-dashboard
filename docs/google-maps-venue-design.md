# Workshop venue autocomplete and directions

Status: scope summary confirmed by the user on 6 November 2026. No implementation,
Google provisioning or production changes authorized.

ALE-439 documentary validation is recorded in
[Google Places terms validation](google-places-terms-validation.md). Its provider
requirements must be resolved within the confirmed venue-name search scope;
address-only autofill was rejected as a replacement. Manual destinations remain
available independently. The native Calendar goal below is unchanged.

## Goal

Help attendees navigate to the right venue from their Calendar Invitation and
attendee-facing workshop page. Google autocomplete is an aid to selecting that
destination, not a requirement for scheduling a workshop.

Calendar integration is already implemented. This feature extends it rather
than introducing another Calendar delivery path. See
[the integration guide](workshop-calendar.md).

## Agreed decisions

Confirmed on 6 November 2026:

- Keep ordinary Google Maps venue-name search: search for a venue, deliberately
  select a result, save the destination, and use it for directions and Calendar's
  native location. The user explicitly rejected an address-only downgrade and
  further product-scope questions about that choice. Resolve provider details
  within this scope rather than presenting speculative restrictions as a reason
  to redesign it.
- Cover regular Workshop create/edit and Beginners' Workshop schedule/reschedule.
- Keep the existing short venue label separate from the selected Google location.
  Beginners' Workshop labels retain their existing 80-character email limit.
- Let staff enter a venue/address manually if Google has no suitable result or is
  unavailable, with an optional manually supplied Maps link.
- Favour Dublin in suggestions without excluding other locations.
- Show directions in Calendar events and attendee-facing workshop pages.
- Use Calendar's native location field, not a Maps link added to the event
  description. The goal is a recognizable, navigable venue in the Calendar UI.
- Include backfill for existing upcoming workshops, including those outside the
  normal regular Workshop edit window. Use a one-off reviewed mapping from
  existing venue text to selected destinations, with a preview of every affected
  upcoming workshop. Never silently choose the first Google search result; leave
  ambiguous venues unchanged for review. Past workshops stay untouched.
- Backfill follows the normal Calendar attendee-update mechanism, accepting that
  Google may send update emails. Enriching the same venue's destination details
  does not trigger separate workshop-rescheduled emails or change its date/time.
  It does not authorize moving a published workshop to another physical venue.
  No production backfill has been authorized or run.
- Leave existing email templates unchanged. This does not suppress Calendar's
  existing attendee-update notifications.
- Do not add an embedded map, coordinates requirement or shared venue directory.
- Preserve the separation between Workshop and Beginners' Workshop storage and
  commands. Reuse the existing Calendar synchronization protocol.

## Verified integration constraints

- `Dhc.WorkshopCalendar.Sync` currently puts the source projection's `location`
  into Google's event `location` field. Committee event descriptions contain the
  protected dashboard link; participant events export no description.
- Google's Calendar event `location` is free-form text, not a structured Place ID
  field. A name/address can populate it, but this alone does not guarantee that
  Calendar resolves the intended Google Place. The published Calendar discovery
  schema also exposes no ordinary-event structured Place field. Verify the native
  location/navigation experience on an authorized isolated calendar rather than
  promising exact Place identity based on an API write alone.
- Existing published-Workshop editing restrictions and Beginners' Workshop
  reschedule/email policies remain in force unless explicitly changed here.
- Google Places has attribution and storage restrictions, including EEA-specific
  terms. The persistence strategy must be checked against the applicable terms;
  do not assume all returned place details can be stored indefinitely.
- Places requires its own API/billing/key configuration; existing Calendar OAuth
  does not establish that Places is configured.
- The owner confirmed that the intended Google Maps billing account is based in
  Ireland/EEA. Use that account region for validation; the actual project and any
  account-specific agreement have not been inspected.

## Authorization boundary

No interview policy questions remain open. The user confirmed the complete scope
summary. Design confirmation is not permission to implement the feature, provision
Google, activate production sending, or backfill production records.

## Implementation and verification scope

- Reuse one autocomplete input across the ordinary Workshop form and the
  Beginners' Workshop schedule/reschedule forms, preserving remote-form bindings,
  keyboard access, field errors and manual fallback.
- Extend each domain's own storage, request/read contracts and Calendar projection
  without merging their commands or tables. Regenerate the typed API client.
- Add attendee-facing directions links without exporting private Intake links,
  tokens or roster details to Google.
- Use the existing Calendar protocol for destination updates, preserving event
  identities, attendees, RSVPs, retry/fencing behaviour and historical cutoffs.
- Provide a preview/apply backfill through authorized source-owned operations,
  re-checking current rows before applying reviewed mappings. Do not bypass
  domain command ownership with direct database updates.
- Test form submissions, manual/failure paths, both API contracts, projections,
  backfill preview/application, normal Calendar update notifications and the
  absence of separate workshop-rescheduled emails for venue enrichment.
- Run affected frontend build/typecheck/lint/unit/browser/E2E coverage, Phoenix
  precommit and API generation/idempotency checks during implementation. Automated
  tests substitute Google; isolated live-Calendar acceptance requires separate
  authorization and synthetic data.

Provisional effort: 3–5 developer days, excluding Google provisioning and human
venue review. Native Calendar navigation behaviour and the applicable Places
storage terms remain technical validation gates, not claims already verified by
the design interview.

## Sources

- [Google Calendar Events resource](https://developers.google.com/workspace/calendar/api/v3/reference/events#location)
- [Google Places policies](https://developers.google.com/maps/documentation/places/web-service/policies)
- [Calendar specification, ALE-429](https://linear.app/alessandrojcm/issue/ALE-429/spec-workshop-calendar-and-calendar-invitations)
- [Current Calendar launch scope, ALE-437](https://linear.app/alessandrojcm/issue/ALE-437/calendar-launch-preview-and-explicit-activation)
