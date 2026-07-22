# M1 authentication migration rehearsal

ALE-166 rehearses M1, the additive population migration that runs while
Supabase Auth remains live. M1 does not rename application columns or repoint
foreign keys; those operations belong to M2/ALE-163 under the cutover write
freeze.

## Safety rules

- Rehearse against a newly restored production backup, never the live database.
- Capture counts and anomaly class names only. Do not copy UUIDs, emails,
  provider subjects, identity payloads, or token material into tickets, logs, or
  retained evidence.
- Any anomaly aborts the migration. Repair the source backup and repeat the
  rehearsal; there is no exclusion manifest or skip-list path.
- Discord linkage is optional. Magic-link-only Members receive Principals
  without External Identities; Discord gates apply only to Discord identities
  that exist in the source.
- A failed transactional migration leaves no target population committed. If a
  successful M1 rehearsal must be reversed, run its `down/0` and verify the
  aggregate rollback audit row.

## Automated rehearsal

Run from the repository root:

```sh
mise run phx-test test/dhc/auth/m1_rehearsal_test.exs
```

The testcontainers fixture creates the GoTrue `auth.identities` shape missing
from the test image, then exercises the same `Dhc.AuthMigration.M1` module that
the Ecto migration invokes. It covers:

- active and inactive Member UUID preservation;
- magic-link-only Members without Discord linkage;
- Member/Principal correspondence;
- Discord-only External Identity import;
- provider-subject and normalized-email constraints;
- orphan, collision, inconsistent-subject, and reconciliation aborts;
- aggregate audit evidence without personal payloads; and
- rollback while preserving Principals created by the Phoenix Invitation
  lifecycle.

## Restored-backup procedure

1. Restore the verified production backup into an isolated database.
2. Point the release candidate at that database with Supabase Auth still
   configured and no application write traffic.
3. Run migrations through M1:

   ```sh
   mix ecto.migrate --to 20260720100002
   ```

4. If M1 aborts, retain only its aggregate exception, for example
   `principal_email_collision (2)`. Repair the source data through controlled
   operator access, discard the failed restore, restore again, and rerun.
5. On success, record the latest aggregate audit row:

   ```sql
   SELECT step, status, counts, created_at
   FROM auth_migration_audit
   WHERE step = 'm1_populate'
   ORDER BY created_at DESC
   LIMIT 1;
   ```

6. Verify the aggregate relationships without selecting identifiers:

   ```sql
   SELECT
     (SELECT count(*)
        FROM auth.users u
        JOIN user_profiles up ON up.supabase_user_id = u.id
        JOIN member_profiles mp
          ON mp.id = u.id AND mp.user_profile_id = up.id) AS source_members,
     (SELECT count(*)
        FROM principals p
        JOIN auth.users u ON u.id = p.id
        JOIN user_profiles up ON up.supabase_user_id = u.id
        JOIN member_profiles mp
          ON mp.id = u.id AND mp.user_profile_id = up.id) AS target_principals,
     (SELECT count(*)
        FROM auth.identities
       WHERE provider = 'discord') AS source_discord_identities,
     (SELECT count(*)
        FROM external_identities
       WHERE provider = 'discord') AS target_discord_identities;
   ```

7. Rehearse rollback:

   ```sh
   mix ecto.rollback --to 20260720100001
   ```

8. Verify the latest `m1_rollback` audit row reports zero source-backed
   Principals and Discord External Identities remaining. Discard the rehearsal
   database after evidence is recorded.

M1 success is necessary but not sufficient for cutover. M2 must repeat
reconciliation under the write freeze before repointing application foreign
keys.
