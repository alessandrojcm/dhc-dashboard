# Notes

## SvelteKit (current)

- Type check with `pnpm check` not `tsc` (Svelte compiler required)
- E2E tests need unique data: `test-${Date.now()}-${randomSuffix}@example.com`
- Use `dinero.js` for money, `day.js` for dates
- TanStack Query uses thunk pattern: `createQuery(() => ({...}))`
- Stripe sync scheduling is Phoenix/Oban-owned through `Dhc.StripeSync.Worker`; the legacy Supabase `functions/stripe-sync` edge function and its manual E2E spec have been removed.
- Members dashboard status filtering supports three states: `active`, `inactive`, `paused`; `paused` means `is_active = true` and `subscription_paused_until` is in the future.
- `member_management_view` now exposes computed `membership_status` (`active`/`inactive`/`paused`) plus `paused_until` aliasing `member_profiles.subscription_paused_until` for member list filtering.

## Phoenix (in progress)

- **Dev database** prefers `DATABASE_URL`; if absent it falls back to local Supabase Postgres (`localhost:54322`, user `postgres`, password `postgres`, database `postgres`). Use `POSTGRES_*` env vars only when `DATABASE_URL` is not set.
- **Phoenix CORS dev origins** must include both `localhost` and `127.0.0.1` forms (e.g. `https://127.0.0.1:5173`) because the Vite dev server may bind to `127.0.0.1` and browsers treat that as a separate origin from `localhost`.
- **Sentry** is configured in `config/runtime.exs` under the `config_env() == :prod` block. It reads `SENTRY_DSN` env var automatically. If unset, no events are sent.
- **Sentry Logs metadata** is allowlisted in `config :sentry, logs: [metadata: ...]`; adding `Logger.info/2` metadata is not enough for it to appear in Sentry. Add new structured log keys to both baseline `config/config.exs` and prod `config/runtime.exs` when introducing operational metadata.
- **Sentry integrations**: `Sentry.PlugContext` in the endpoint (request context on errors), Oban integration (failed job capture + cron monitoring), `Sentry.LoggerHandler` (forwards `Logger.error/1` and crashes to Sentry).
- **All 11 Ecto baseline migrations** are marked "up" on the shared Supabase Postgres. The tables already existed from Supabase migrations; Ecto migration versions were inserted into `schema_migrations` to mark them as run.
- If `mix test`/`mix ecto.migrate` reports duplicate baseline objects such as `type "role_type" already exists` against local Supabase, the database has Supabase schema objects but missing Ecto `schema_migrations` rows; do not add duplicate migrations to fix this. Restore/mark the baseline migration versions or use the documented shared Supabase Postgres state.
- **First-time Phoenix setup** on a fresh database: `mix setup` (deps.get + ecto.create + ecto.migrate).
- **Workshop Announcements Worker** (`Dhc.WorkshopAnnouncements.Worker`): Migrated from `process-workshop-announcements` Deno edge function. Fan-out pattern: one incoming Oban job produces downstream `Dhc.Discord.Worker` and `Dhc.Email.Worker` jobs. Context module (`Dhc.WorkshopAnnouncements`) handles DB queries and message formatting, keeping the worker focused on job orchestration.
- **Migrated Oban worker data access**: keep workers as orchestration modules. Put Postgres queries behind domain repository modules such as `Dhc.Invitations.Repository` or `Dhc.StripeSync.Repository` so the worker interface stays small and data access has locality. Prefer Ecto schemas/repositories for migrated tables over carrying forward raw SQL from edge functions.
- **Phoenix API auth**: protected JSON endpoints validate Supabase bearer JWTs via `supabase_auth`/`supabase_potion` in `Dhc.Auth.SupabaseJwt`; role checks read `app_metadata.roles` through `DhcWeb.Plugs.RequireAuth`.
- **Array unnest distribution queries**: to count elements of a Postgres array column in Ecto (e.g. `Dhc.Members.weapon_distribution/0` over `member_profiles.preferred_weapon[]`), use an `inner_lateral` join over a `SELECT col FROM unnest(?) AS t(col)` fragment and address the named column via `w.col` (e.g. `select: %{weapon: w.weapon, value: count()}`). Ecto rejects selecting the *whole* fragment binding (`w`), so the unnested value must be given a real column name via `AS t(weapon)` inside the fragment and referenced as `w.weapon`. The lateral join lets the fragment reference the correlated outer array column.
- **Phoenix dev Supabase auth config**: `config/dev.exs` reads `SUPABASE_URL`/`SUPABASE_ANON_KEY`, falling back to SvelteKit's `PUBLIC_SUPABASE_URL`/`PUBLIC_SUPABASE_ANON_KEY` from the root `.env` so local bearer JWT verification works under `mise run phx-server`; service-role operations read `SUPABASE_SERVICE_ROLE_KEY` with local fallback `SERVICE_ROLE_KEY`.
- **Migrated Supabase timestamp columns**: legacy tables such as `user_profiles` and `invitations` use `created_at`/`updated_at`, not Ecto's default `inserted_at`/`updated_at`; schemas should use `timestamps(inserted_at: :created_at, type: :utc_datetime)` when mapping those tables.
- **Invitation API routes**: model invitations as resources. Use `POST /api/invitations` to enqueue invitation creation and `POST /api/invitations/resend` to resend existing invitations; avoid verb/resource names such as `/bulk-invitations` or `/invitation-resends`.
- **SvelteKit → API remotes**: server-side remote functions call generated `@dhc/api-client` SDK functions using `apiClientOptions(session)` from `$lib/server/api-client`; the centralized base URL reads `API_BASE_URL`, then legacy `PHOENIX_API_BASE_URL`/`PHOENIX_API_URL`, with dev fallback `http://localhost:4000/api`.
- **Phoenix-generated frontend links**: use configured `:app_url` (`APP_URL` in prod/runtime, dev may fall back to `PUBLIC_SITE_URL`/`SITE_URL`); domain code should call `Application.fetch_env!(:dhc, :app_url)` rather than hardcoding localhost fallbacks.
- **Phoenix integration tests** are tagged `:integration` and excluded from the default `mix test` run. Run them with `mix test --include integration`; the Stripe sync integration test hits Stripe test mode, creates its own customers/subscriptions, and requires `STRIPE_SECRET_KEY` plus either `STRIPE_SYNC_TEST_PRICE_ID` or a Stripe test price with `lookup_key=standard_membership_fee`.
- **`mix dhc.seed_members [COUNT]`** creates Supabase auth users, waitlist entries, user profiles, member profiles, user roles, and Stripe customers. It is the Elixir equivalent of `scripts/seedMembers.js`.
- **Phoenix Docker runtime** runs as `nobody` and launches through the mise-installed `fnox` shim. Keep `HOME` and `MISE_STATE_DIR` pointed at writable paths in `apps/phoenix/Dockerfile`; local `docker run dhc-api` should advance to 1Password auth/secret resolution rather than failing with filesystem permission errors.
- **Fly health checks** hit `GET /api/health` over internal HTTP on the configured `PORT`; keep that path excluded from Phoenix `force_ssl` redirects in `config/prod.exs` while leaving Fly `force_https = true` enabled for public traffic.
- **Phoenix release env hooks** under `apps/phoenix/rel/` must be copied in `apps/phoenix/Dockerfile` before `mix release`; Fly longname configuration lives in `rel/env.sh.eex` so release builds should log `creating .../env.sh`.
