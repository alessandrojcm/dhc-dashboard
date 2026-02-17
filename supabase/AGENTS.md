# SUPABASE LAYER

PostgreSQL database, edge functions, and testing infrastructure.

## STRUCTURE

```
supabase/
├── migrations/       # Timestamped SQL migrations
├── functions/        # Deno edge functions
│   ├── _shared/      # Shared utilities (db.ts, kyselyDriver.ts)
│   ├── stripe-webhooks/
│   ├── stripe-sync/
│   ├── bulk_invite_with_subscription/
│   ├── process-emails/
│   ├── process-discord/
│   └── process-workshop-announcements/
├── tests/database/   # pgTAP unit tests
├── templates/        # Email templates (invite.html, magiclink.html)
├── config.toml       # Supabase configuration
└── seed.sql          # Initial data + extensions
```

## MIGRATIONS

**Naming**: `YYYYMMDDHHMMSS_description.sql`

**Security Pattern**:
```sql
CREATE OR REPLACE FUNCTION my_function()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''  -- Prevents search path injection
AS $$
BEGIN
  -- Use fully qualified names: public.table_name
END;
$$;
```

**After Migration**: Run `pnpm supabase:types`

## EDGE FUNCTIONS

**Runtime**: Deno 2

**Shared Code**: `_shared/` contains Kysely driver for type-safe SQL in Deno

```typescript
// In edge function
import { getKyselyClient } from '../_shared/db.ts';

const db = getKyselyClient();
const result = await db.selectFrom('users').selectAll().execute();
```

**JWT Verification**: Disabled for webhooks in `config.toml`

## RLS & RBAC

### Role Management

Roles stored in `public.user_roles`, injected into JWT via `custom_access_token_hook`.

### Helper Functions

```sql
-- Check single role
SELECT has_role(auth.uid(), 'admin');

-- Check any of multiple roles (SECURITY DEFINER)
SELECT has_any_role(auth.uid(), ARRAY['admin', 'president']::role_type[]);
```

### RLS Policy Pattern

```sql
CREATE POLICY "Members can view own data"
ON public.table_name
FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Admins can do everything"  
ON public.table_name
FOR ALL
USING (has_any_role(auth.uid(), ARRAY['admin']::role_type[]));
```

## DATABASE TESTING (pgTAP)

**Location**: `supabase/tests/database/`

**Pattern**:
```sql
BEGIN;
SELECT plan(3);

-- Setup test user
SELECT tests.create_supabase_user('test_user', 'test@example.com');
SELECT tests.authenticate_as('test_user');

-- Test RLS
SELECT results_eq(
  'SELECT count(*) FROM my_table',
  ARRAY[1::bigint],
  'User can only see own records'
);

SELECT finish();
ROLLBACK;
```

**Helpers**: `tests.authenticate_as()`, `tests.create_supabase_user()`

## KEY TABLES

| Table | Purpose |
|-------|---------|
| `user_profiles` | Core user data |
| `member_profiles` | Membership details |
| `user_roles` | RBAC role assignments |
| `club_activities` | Workshops/events |
| `workshop_attendees` | Registrations |
| `equipment_*` | Inventory system |
| `invitations` | Member onboarding |

## COMMANDS

```bash
pnpm supabase:start          # Start local instance
pnpm supabase:functions:serve # Serve edge functions
pnpm supabase:reset          # Reset + reseed
pnpm supabase:types          # Generate TypeScript types
```

## ANTI-PATTERNS

- Missing `SET search_path` in functions
- RLS policies without `has_any_role` for admin access
- Direct table access without RLS consideration
- Skipping `ROLLBACK` in tests

## STRIPE SYNC NOTES

- `functions/stripe-sync` is batch-based: it paginates Stripe subscriptions filtered by `standard_membership_fee` and applies the newest subscription per customer.
- `functions/stripe-sync` should reuse `settings.stripe_monthly_price_id` when cache age is <=24h; refresh from Stripe and update settings when stale/missing.
- Default sync scope is stale members only (`member_profiles.updated_at` older than 24h); manual runs can pass `customer_ids` payload to force targeted sync.
- Cron scheduling for stripe sync should be a single daily invocation (`0 0 * * *` UTC) calling `/functions/v1/stripe-sync` once.
