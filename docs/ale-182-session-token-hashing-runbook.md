# ALE-182 Session Token Hashing Runbook

ALE-182 changes stored session tokens from plaintext cookies to SHA-256 digests.
The old application reads and writes plaintext while the new application reads
and writes digests, so the migration must not run during a rolling deployment.

## Before The Window

1. Confirm a restorable database backup exists.
2. Announce a short maintenance window for the Phoenix API.
3. Confirm the release artifact contains both the ALE-182 migration and the
   digest-backed session code.

## Deploy

1. Stop or drain every old Phoenix instance.
2. Confirm no old instance can receive traffic or create sessions.
3. Run the Fly release command once to apply all pending migrations.
4. Start only the new release.
5. Verify an existing session cookie still authenticates.
6. Create and revoke a new session, then confirm the database stores a
   32-byte digest rather than the raw cookie.
7. Restore normal traffic.

Do not start an old release after step 3. It cannot read migrated sessions and
would create plaintext sessions that the new release cannot authenticate.

## Rollback

The token backfill is one-way. If the release cannot proceed after migration,
stop the new instances and restore the pre-window backup. Do not run a partial
schema rollback.
