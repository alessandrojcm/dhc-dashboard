# M2 Phoenix authentication cutover runbook

ALE-163 is the production cutover from Supabase Auth to Phoenix-owned
Principals and Sessions. M2 is transactional, runs under a write freeze, deletes
pending Invitations, renames the two application ownership columns, and
repoints all 17 application ownership foreign keys to `principals.id`.
`invitations.user_id` remains unconstrained because a pending Invitation holds
the UUID of a Principal that does not exist until acceptance.

Supabase `auth.*` remains in place as rollback dead weight only during the
seven-day observation window. The subsequent Postgres-hosting migration removes
it after the observation window closes; the application has no runtime
dependency on that schema. No Supabase session, access token, refresh token, or
GoTrue state is migrated.

## Roles and evidence

Assign these roles before scheduling the window:

- **Cutover commander:** owns go/no-go decisions and the event log.
- **Database operator:** verifies the backup, runs migrations, and owns restore.
- **Release operator:** deploys and rolls back the Phoenix and SvelteKit releases.
- **Verifier:** performs smoke checks and watches aggregate telemetry.
- **Communications owner:** posts maintenance and completion updates.

Record timestamps, release identifiers, migration status, aggregate counts,
smoke-check results, and decisions. Never retain UUIDs, emails, provider
subjects, cookies, or token material as evidence.

## Before the maintenance window

1. Complete the M1 restored-backup rehearsal in
   [`auth-m1-rehearsal.md`](auth-m1-rehearsal.md), including its rollback.
2. Rehearse M2 and its rollback from the repository root:

   ```sh
   mise run phx-test test/dhc/auth/m2_cutover_rehearsal_test.exs
   ```

3. Verify the release candidates contain the matching Phoenix-auth API and
   frontend, and retain the previous Supabase-auth release identifiers for
   rollback.
4. Confirm access to maintenance controls, database backup/restore, Supabase
   Auth session invalidation and provider settings, deployment controls,
   dashboards, and alerting.
5. Confirm Phoenix cookie-signing, magic-link sender, and Discord OAuth secrets
   are present. Keep retired Supabase credentials available only to the rollback
   operators during observation.
6. Announce the maintenance window and expected forced sign-in. State that all
   existing sessions will end and pending, unaccepted Invitations will be
   removed and must be reissued.
7. Freeze unrelated production releases until observation begins.

## Cutover

The commander records each completed step. Stop on any unexpected result.

1. Enable maintenance mode and post: “DHC Dashboard sign-in is temporarily
   unavailable for scheduled authentication maintenance. Existing sessions will
   be signed out. We will post again when service is restored.”
2. Confirm there is no application write traffic.
3. Take a fresh database backup and verify that it is restorable. Record its
   identifier and timestamp; do not proceed without a verified restore point.
4. Deploy the Phoenix-auth API release without reopening public traffic.
5. Run migrations through M2:

   ```sh
   mix ecto.migrate --to 20260721100000
   ```

   M2 must abort on reconciliation drift, a Principal/Member mismatch, or an
   invalid foreign-key target. A failed migration transaction is a no-go; do not
   bypass its gate.
6. Record the latest aggregate M2 audit row:

   ```sql
   SELECT step, status, counts, created_at
   FROM auth_migration_audit
   WHERE step = 'm2_cutover'
   ORDER BY created_at DESC
   LIMIT 1;
   ```

7. Verify aggregate schema state without selecting personal data:
   - `user_profiles.principal_id` exists and `supabase_user_id` does not;
   - `user_roles.principal_id` exists and `user_id` does not;
   - all 17 migrated application foreign keys target `principals.id`;
   - no pending Invitations remain; and
   - every referenced Principal has its required Member profile.
8. Invalidate every Supabase Auth session using the approved Supabase operator
   control. Confirm the operation completed; do not copy session data into the
   event log.
9. Deploy the matching Phoenix-auth frontend.
10. Keep maintenance mode enabled while completing every smoke check below.

## Required smoke checks

Use designated test Members and record pass/fail only:

1. Request and consume a magic link; verify session creation and dashboard/API
   access.
2. Sign in through Discord as an imported, linked Member.
3. Verify an authorized Member can access a protected endpoint.
4. Verify a request without a valid Phoenix session receives `401`.
5. Verify an authenticated Member missing a required role receives `403`.
6. Accept a newly issued Invitation, verify no session is created by acceptance,
   then complete the first normal sign-in.
7. Verify logout revokes the current Phoenix session.

If every check passes and aggregate telemetry is healthy, reopen traffic and
post: “DHC Dashboard maintenance is complete. Previous sessions were signed
out; please sign in again.” Start the seven-day observation clock.

## Rollback

Rollback is required if M2 commits but deployment, session invalidation,
frontend compatibility, or a required smoke check fails. Do not attempt an
in-place mixed-auth repair.

1. Keep or return the site to maintenance mode and stop application writes.
2. Preserve aggregate error and audit evidence only.
3. Restore the verified pre-cutover backup.
4. Redeploy the previous Supabase-auth Phoenix API and SvelteKit frontend as one
   release pair.
5. Verify the restored database and old releases with their pre-cutover smoke
   checks.
6. Reopen traffic only after the commander confirms the restored service.
7. Announce rollback and rescheduling. Repair the underlying issue and repeat
   both restored-backup rehearsals before another attempt.

Do not use `mix ecto.rollback` as the production recovery mechanism after users
could have generated post-cutover writes. The M2 `down/0` path is for isolated
rehearsal; production recovery uses the verified backup.

## Seven-day observation

Keep Supabase Auth configured but unused. The verifier reviews aggregate,
non-personal telemetry after reopening, hourly for the first four hours, daily
thereafter, and before retirement:

- auth success/failure grouped by magic link and Discord;
- session-validation failures grouped by reason;
- Discord link/collision failures;
- `401` and `403` rates on authenticated routes;
- M1/M2 reconciliation or audit mismatches; and
- application error rate and latency for authenticated endpoints.

Page the cutover commander immediately for any reconciliation/audit mismatch,
any evidence of a production Supabase bearer-token path, repeated login failure
for both methods, or a sustained material increase in authenticated endpoint
errors. Pause credential retirement while any auth incident remains open.

## Retire Supabase Auth after day seven

When seven complete days are healthy and the commander signs off:

1. Record the final aggregate telemetry and audit review.
2. Disable Supabase Auth providers.
3. Revoke and remove Supabase Auth credentials from runtime secret stores,
   deployment configuration, and operator access.
4. Confirm Phoenix has no Supabase Auth network traffic and both login methods
   still pass.
5. Confirm the completed Postgres-hosting migration removed `auth.*`; do not
   recreate or retain the schema. Close the maintenance record.
