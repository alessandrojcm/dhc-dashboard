# Notes

## SvelteKit (current)

- Type check with `pnpm check` not `tsc` (Svelte compiler required)
- E2E tests need unique data: `test-${Date.now()}-${randomSuffix}@example.com`
- Use `dinero.js` for money, `day.js` for dates
- TanStack Query uses thunk pattern: `createQuery(() => ({...}))`
- `supabase/functions/stripe-sync` now runs in batch mode: it fetches all `standard_membership_fee` subscriptions via Stripe pagination and syncs only customer IDs where `member_profiles.updated_at` is older than 24h.
- `supabase/functions/stripe-sync` reuses cached Stripe monthly price ID from `settings.stripe_monthly_price_id` when it is <=24h old, and refreshes cache from Stripe when stale/missing.
- Stripe sync cron should call the edge function once daily (UTC midnight) instead of one HTTP request per customer; migration `20260217103000_refactor_stripe_sync_cron_batch.sql` handles unschedule/reschedule.
- Manual Stripe sync E2E is gated by `RUN_STRIPE_SYNC_MANUAL_E2E=true` in `e2e/stripe-sync-manual.spec.ts` and validates sync by seeding data, mutating Stripe state, then invoking `/functions/v1/stripe-sync` directly.
- Members dashboard status filtering supports three states: `active`, `inactive`, `paused`; `paused` means `is_active = true` and `subscription_paused_until` is in the future.
- `member_management_view` now exposes computed `membership_status` (`active`/`inactive`/`paused`) plus `paused_until` aliasing `member_profiles.subscription_paused_until` for member list filtering.

## Phoenix (in progress)

- **Dev database** defaults to Supabase local Postgres (Docker on `localhost:54322`, user `postgres`, password `postgres`, database `postgres`). Override via `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB` env vars.
- **Sentry** is configured in `config/runtime.exs` under the `config_env() == :prod` block. It reads `SENTRY_DSN` env var automatically. If unset, no events are sent.
- **Sentry integrations**: `Sentry.PlugContext` in the endpoint (request context on errors), Oban integration (failed job capture + cron monitoring), `Sentry.LoggerHandler` (forwards `Logger.error/1` and crashes to Sentry).
- **All 11 Ecto baseline migrations** are marked "up" on the shared Supabase Postgres. The tables already existed from Supabase migrations; Ecto migration versions were inserted into `schema_migrations` to mark them as run.
- **First-time Phoenix setup** on a fresh database: `mix setup` (deps.get + ecto.create + ecto.migrate).
- **Workshop Announcements Worker** (`Dhc.WorkshopAnnouncements.Worker`): Migrated from `process-workshop-announcements` Deno edge function. Fan-out pattern: one incoming Oban job produces downstream `Dhc.Discord.Worker` and `Dhc.Email.Worker` jobs. Context module (`Dhc.WorkshopAnnouncements`) handles DB queries and message formatting, keeping the worker focused on job orchestration.
