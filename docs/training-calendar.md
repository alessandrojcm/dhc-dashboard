# Training calendar sharing

`Dhc.TrainingCalendar.sync/0` keeps eligible people on one existing Google
training calendar as **readers**. It manages sharing only: it never creates,
reads or edits training events, and does not change Workshop invitations or
Training Announcements. There is no new UI or HTTP API.

## Eligibility and schedule

- Members qualify while `user_profiles.is_active` is true and their
  `subscription_paused_until` is absent or no later than the pass's current time.
- Coaches qualify while their profile is active, regardless of membership or
  pause. Coaching roles are resolved only by `Dhc.Auth.Capabilities`.
- The address is the Principal's current login email. An address change removes
  the old sync-managed share and grants the new one on the next pass.

`Members.training_calendar_emails/1` owns this live projection. Jobs have empty
arguments and read current eligibility when they run, including retries.

The Oban worker acts at **00:00 Europe/Dublin**, including daylight-saving time.
The existing Cron plugin remains UTC for every other job: its `00:00` and
`23:00` UTC ticks wake this worker, which ignores whichever isn't Dublin
midnight. A queued midnight job still acts after a delay, and its bounded retries
can run outside midnight. As with ordinary Cron, server downtime covering the
tick is repaired by the next daily pass; there is no startup catch-up sweep.
The 55-minute job-uniqueness window prevents a queued alternate tick from
suppressing the real midnight job an hour later; the database lock still
serializes overlapping executions.

## Ownership and failures

The `training_calendar_grants` ledger is scoped by explicit calendar ID and
email. It has no source foreign keys, so an unlinked/deleted person cannot erase
an owed removal. Existing user shares, owners, groups, public and domain rules
are **not adopted or revoked**. Eligible people with a pre-existing free/busy-only
share are reported as `insufficient_access` for an administrator to resolve,
rather than silently changing a manual rule.

An administrator's change to a managed rule's role, ID or ETag relinquishes
management of that share. Revocation uses `If-Match`, so a concurrent edit cannot
be overwritten. Missing managed shares are recreated for eligible people.
Unchanged passes make no Google mutations and send no repeated sharing emails.

An insert is recorded locally before Google is called. If Google succeeds but
the acknowledgment is lost, the next pass adopts that pending reader rule,
without sending another notification, and can revoke it if eligibility ended.
An uncertain insert not yet visible on Google retains its cleanup obligation
and reports `uncertain_grant`; absence alone cannot prove a delayed request will
never arrive. Do not delete ledger rows to clear errors. Avoid concurrent manual
sharing changes while an insert is unacknowledged: Google's ACL API has no custom
ownership marker or conditional insert, so a pending reader rule cannot be
distinguished from an identical, concurrently created manual share.

All ACL pages are read successfully before any mutation. One rejected recipient
does not block valid additions or owed removals. The worker makes at most three
attempts per job; the next daily job retries remaining current work. Errors are
closed reason atoms/counts, never addresses, provider bodies or credentials.
Existing Oban/Sentry reporting handles job failures; no dashboard Notifications
are added.

A target-scoped PostgreSQL session advisory lock serializes passes across nodes.
The pass holds one Repo connection, **not an open database transaction**, during
bounded Google requests. Use a direct or session-pooled database connection,
never a transaction-pooling proxy. An active pass causes a concurrent one to
return `{:ok, :busy}`. The worker has a 30-minute execution limit.

## Provisioning and enabling

Deployment is **disabled by default**. Supplying credentials alone does not
enable sharing. Production provisioning, first sharing emails and enablement
require separate operator authorization; automated development never contacts
live Google.

1. Apply the additive ledger migration before enabling the worker.
2. Choose an explicit existing training-calendar ID, distinct from the Workshop
   committee and participant calendars. The `primary` alias and either configured
   Workshop calendar ID are refused.
3. Use separate organizer OAuth credentials with offline consent for only
   `https://www.googleapis.com/auth/calendar.acls`. The organizer must be allowed
   to manage sharing on this target. Do **not** broaden or reuse the Workshop
   Calendar's event-only refresh grant; there is no domain-wide delegation.
4. Review existing manual, group, domain and public sharing. Preserving it means
   this sync cannot guarantee that only eligible people have effective access.
5. Provision these production 1Password items using the existing secret-manager
   workflow; `fnox.toml` includes their references and inactive/empty fallbacks:

   ```text
   TRAINING_CALENDAR_ENABLED=false
   TRAINING_CALENDAR_ID
   TRAINING_CALENDAR_CLIENT_ID
   TRAINING_CALENDAR_CLIENT_SECRET
   TRAINING_CALENDAR_REFRESH_TOKEN
   ```

6. Verify the behavior first with separate isolated credentials/calendar and
   synthetic recipients. A different target is not a production-data sanitizer.
7. Once authorized, set `TRAINING_CALENDAR_ENABLED=true` and restart the Phoenix
   process to reload secrets. The next Dublin-midnight pass shares the calendar
   with existing eligible people. New grants request Google's sharing email
   (`sendNotifications=true`); unchanged passes do not send another.

Setting enabled to false stops future passes; it does **not** revoke existing
shares or cancel a request already in flight. Changing the calendar ID does not
clean the previous calendar: its ledger remains target-bound. Review/clean up the
old target before switching, rather than discarding its ledger.

Sharing gives access, not guaranteed delivery or automatic subscription/display
in the recipient's Calendar list. People may need to accept Google's sharing
email or add the shared calendar themselves. This does not impersonate members
or modify their personal calendar lists. Google ownership/Workspace permissions
and retained external data remain outside this sync's control.

## Verification

All Google/OAuth requests are replaced through `Req.Test`. The Phoenix
Testcontainers harness supplies a disposable database, including real concurrent
connections for the serialization test:

```sh
cd apps/phoenix
mise exec -- env DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock \
  mix test test/dhc/training_calendar test/dhc/auth/capabilities_test.exs
mise exec -- mix precommit
```

The socket overrides are needed with Colima; other environments should use their
own Docker connection. These tests do not claim live-Google or production
acceptance coverage.
