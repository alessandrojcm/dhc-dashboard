# ADR 0031: One organizer connection for Google Calendar

**Status:** Accepted
**Date:** 2026-11-23

## Context

Workshop Calendar used an event-only organizer credential. Training Calendar
sharing used a separate ACL-only credential, even though the calendars belong
to the same organizer. Both transports independently loaded credentials,
exchanged tokens and classified failures.

A production `invalid_client` failure required manually distinguishing the
secret manager's current values from the credentials loaded by Phoenix.
Separate credentials and indistinguishable `unauthorized` errors made repair
harder without providing process isolation: both credentials lived in one app.

## Decision

Use one Google OAuth client and one offline organizer grant with exactly
`calendar.events.owned` and `calendar.acls`. `Dhc.GoogleCalendar.Auth` owns
credential loading, token exchange, granted-scope validation and closed error
classification. No other module loads the credentials.

Keep three distinct target IDs and the existing independent sending controls.
Event and ACL transports retain their own interfaces and implementations.
Reconciliation, ETags, ownership ledgers and attendee privacy do not move.
Credentials alone never activate either workflow.

Expose read-only diagnostics for the loaded connection and each configured
target, with both a cold Mix command and a running-release RPC interface.
Diagnostics must not start workers or reveal credentials or calendar contents.

This supersedes the separate ACL-only/event-only credential requirement in the
earlier Training and Workshop Calendar integration guides. It does not authorize
production provisioning or activation.

## Consequences

- One credential rotation and one token-exchange implementation serve both
  workflows. `invalid_client` and revoked grants have distinct repair actions.
- Credential failure affects both workflows. A compromised shared grant exposes
  both permissions across calendars available to the organizer, not just our
  configured targets. This is an accepted trade-off for this single-organizer,
  single-process application, not a claim of equivalent permission isolation.
- A same-client secret rotation preserves Workshop activation; changing the
  client ID still requires explicit reactivation.
- Cutover needs new consent and pre-provisioned secrets. Old single-scope grants
  are rejected; there is no silent compatibility fallback.
- Production and isolated testing continue to use separate credentials and data.

## Alternatives

Keeping separate clients/grants behind one implementation would retain
provider-level separation but keep the operational duplication. One shared
client with independently scoped refresh tokens would still require managing
multiple grants and their consent/revocation behavior. A generic credential
registry, administration screen or service-account migration is unnecessary
for the one organizer we actually have.
