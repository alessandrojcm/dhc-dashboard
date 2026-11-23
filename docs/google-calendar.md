# Google Calendar connection

Workshop events and Training Calendar sharing use one organizer connection,
owned by `Dhc.GoogleCalendar.Auth`. Each workflow keeps its own targets,
enablement, durable rows and reconciliation. See [ADR 0031](adr/0031-one-google-calendar-connection.md).

## Configuration

Provision these secrets together in Doppler project `dhc-dashboard`, config
`prd`:

```text
GOOGLE_CALENDAR_CLIENT_ID
GOOGLE_CALENDAR_CLIENT_SECRET
GOOGLE_CALENDAR_REFRESH_TOKEN
```

The offline organizer grant must contain exactly:

- `https://www.googleapis.com/auth/calendar.events.owned`
- `https://www.googleapis.com/auth/calendar.acls`

Consent to both permissions is required. Do not substitute the broad `calendar`
scope. Refresh responses must declare both scopes; an omitted, incomplete or
broader scope set is refused. Google scope order does not matter.

These are account-level permissions, not permissions restricted to our three
configured calendars. The shared connection can exercise both permissions;
separate application transports are not provider-enforced isolation. Use a
dedicated organizer owning the two Workshop calendars and able to manage sharing
on the Training Calendar. Do not introduce domain-wide delegation.

Targets remain separate:

```text
WORKSHOP_CALENDAR_COMMITTEE_ID
WORKSHOP_CALENDAR_PARTICIPANT_ID
TRAINING_CALENDAR_ID
```

Keep all three distinct. Workshop target-bound activation and
`TRAINING_CALENDAR_ENABLED` are unchanged: configuring a connection never enables
either workflow. Keep isolated credentials, calendars and synthetic recipients
separate from production.

## Read-only checks

```sh
cd apps/phoenix
mise exec -- mix dhc.google_calendar.check
```

The command loads configuration and starts Req only, not Phoenix, Oban or Repo.
It exchanges a token and reads each calendar, including when sending is disabled.
It never writes to Google or the database. An authentication failure skips
calendar reads; one inaccessible calendar does not prevent checking the others.
It prints only statuses and fails with a nonzero exit if any check fails.

| Status | Operator action |
| --- | --- |
| `configuration` | Supply the three connection values or the explicit target ID. |
| `invalid_client` | Check the OAuth client ID and secret in Google Cloud Console. |
| `reauthorization_required` | Repeat offline organizer consent; replace the refresh token. |
| `missing_permissions` | Consent to both required scopes and obtain a new grant. |
| `unexpected_permissions` | Obtain a grant limited to the two allowed scopes. |
| `target_inaccessible` | Check target ownership and sharing permissions. |
| `unauthorized` | Google rejected the access token on a calendar read. |
| `transient` | Retry later; Google or the transport is unavailable or rate-limited. |

The check does not prove that future writes will succeed. In particular, a
successful ACL read is not a write-permission test. Mutation acceptance belongs
to separately authorized isolated/live verification.

### Check the running application

Secrets are loaded at boot. A successful local/Doppler check says nothing about
the values already loaded by Phoenix. After an authorized restart, use RPC:

```sh
bin/dhc rpc 'IO.inspect(Dhc.GoogleCalendar.check())'
```

On Fly, use `fly ssh console -a dhc-dashboard` and run this from `/app`.
Use `rpc`, not `eval`: a new release node does not inherit the running node's
fnox-resolved secrets. The report includes no credentials, target IDs, calendar
contents or recipient addresses. Never inspect the raw application configuration.

## Cutover from per-workflow credentials

This cutover requires separate production authorization; implementing the code
does not authorize consent, secret writes, activation or deployment.

1. Retain the existing target IDs and all Calendar ledgers.
2. Prefer the existing Workshop OAuth client if suitable, and obtain a new
   organizer refresh grant covering exactly the two scopes. An existing
   event-only or ACL-only token cannot simply be renamed.
3. Provision all three `GOOGLE_CALENDAR_*` values **before deployment**. fnox
   batches mappings; a missing key fails secret resolution for the application.
4. Verify the new connection and target reads in an authorized operator session.
   Do not run workers just to check credentials.
5. Deploy/restart once authorized, then run the RPC check on the actual node.
6. Review Workshop activation. Its key still includes environment, both calendar
   IDs and the client ID, in the same order and encoding. Keeping that identity
   preserves activation; changing it disables sending until an explicit
   preview/activation. Rotating just the client secret does not invalidate it.
7. Run separately authorized reconciliation and verify job outcomes. Retain
   rollback credentials until both workflows are verified.
8. Retire unused per-workflow credentials and old Doppler mappings after the
   rollback window. Do not revoke a Google grant still used by the new connection.

The old `WORKSHOP_CALENDAR_{CLIENT_ID,CLIENT_SECRET,REFRESH_TOKEN}` and
`TRAINING_CALENDAR_{CLIENT_ID,CLIENT_SECRET,REFRESH_TOKEN}` names are no longer
read. There is deliberately no fallback that could silently select another
organizer or grant.
