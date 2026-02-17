# Stripe Sync Batch Refactor Plan

## Objective

Refactor `supabase/functions/stripe-sync/` so the cron job performs one daily batch sync (UTC midnight) and avoids Stripe rate limiting caused by one-customer-per-request polling.

## Constraints

- Keep existing membership status business logic.
- Process only local members whose `member_profiles.updated_at` is older than ~24h (`now() - interval '1 day'`, UTC semantics).
- Determine membership status from Stripe subscriptions for `standard_membership_fee` only.
- If a customer has multiple matching subscriptions, use the newest subscription regardless of status.
- Handle partial failures per customer (log to Sentry, continue).
- Keep cron runnable in production and local environments.
- Add a manual local E2E test flow using Stripe CLI (`customer.subscription.updated`).

## Implementation Stages

### Stage 1: Edge Function Batch Sync Refactor

1. Update `supabase/functions/stripe-sync/index.ts` to:
   - Initialize Sentry and capture per-customer errors.
   - Keep service-role auth check.
   - Support optional payload `{ customer_ids?: string[] }` for targeted manual runs.
   - Default selection query:
     - Join `user_profiles` + `member_profiles`.
     - Include non-empty `customer_id`.
     - Filter `member_profiles.updated_at < now - 1 day` (or null).
2. Replace per-customer Stripe call pattern with batch listing:
   - Resolve `standard_membership_fee` price ID once.
   - Page through `stripe.subscriptions.list({ price, status: 'all', limit: 100, starting_after })`.
   - Build `customer_id -> newest subscription` map.
3. Apply existing status update logic against local target customers:
   - Missing subscription or canceled/unpaid/incomplete_expired -> inactive user.
   - `pause_collection` present -> update `subscription_paused_until`.
   - Active -> clear pause, update payment/end dates, set active.
4. Return run summary (`processed`, `updated`, `failed`, etc.).

### Stage 2: Cron Migration Fix

1. Add a new migration to replace loop-based cron behavior.
2. New SQL should:
   - `create extension if not exists pg_cron;`
   - Define/replace `sync_all_stripe_customers()` that performs one `net.http_post` to `/functions/v1/stripe-sync` with `{}` body.
   - Unschedule any existing `sync-stripe-customers-daily` job by name if present.
   - Re-schedule it at `0 0 * * *` UTC.
3. Keep secrets sourced from `vault.decrypted_secrets` (`project_url`, `service_role_key`).

### Stage 3: Manual Local E2E Test

1. Add a manual Playwright spec under `e2e/` gated by env flag (not CI default).
2. Test flow:
   - Create a member with Stripe subscription fixtures.
   - Mutate Stripe subscription state (for example cancel or pause the membership subscription).
   - Invoke `stripe-sync` function.
   - Assert local profile status fields changed as expected.
3. Include clear env requirements and command in the spec name/skip reason.

### Stage 4: Validation

1. Run targeted checks:
   - Typecheck the updated edge function and test file.
   - Run the manual spec only when env flag is present.
2. Verify migration SQL syntax by inspection and project conventions.

## Expected Outcome

- Cron runs once per day with one function invocation.
- Stripe API usage is batched via paginated subscriptions listing (no per-customer API calls).
- Membership sync remains behavior-compatible while adding better resilience and observability.
