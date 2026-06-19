# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-12  
**Commit:** (latest)  
**Status:** Active migration from SvelteKit + Supabase to Phoenix + Ecto + Oban

## OVERVIEW

Dublin Hema Club dashboard: currently SvelteKit 2.x + Svelte 5 + Supabase + Stripe. Progressive migration to Phoenix + Ecto + Oban underway. Member management, workshops, payments, inventory.

**Phase 1**: Edge functions → Oban, then service layer → Phoenix API. SvelteKit consumes Phoenix via typed OpenAPI client.
**Phase 2** (future): Evaluate LiveView migration.

## STRUCTURE

```
dhc-dashboard/
├── apps/                      # Phoenix app (active)
│   └── phoenix/
│       ├── config/            # Ecto + Oban config per env
│       ├── lib/dhc/           # Ecto repo + contexts + Oban workers
│       │   ├── repo.ex        # Ecto Repo (connects to shared Postgres)
│       │   └── ...
│       ├── lib/dhc_web/       # Phoenix web layer (JSON API)
│       ├── lib/mix/            # Custom Mix tasks
│       │   └── tasks/          # gen.controllers, dhc.seed_members, etc.
│       ├── dev/                # Dev-only compile path (elixirc_paths(:dev))
│       │   ├── dev_seeds.ex    # Faker-backed seed runner (concurrent)
│       │   └── mix/tasks/      # seed.members, seed.waitlist, seed.committee_members
│       └── priv/
│           ├── repo/migrations/  # 11 baseline Ecto migrations (new source of truth)
│           └── api/              # OpenAPI spec (contract) — active
├── packages/
│   └── api-client/            # Generated TypeScript client from OpenAPI spec
│       ├── openapi-ts.config.ts  # Config: reads spec, outputs src/client/
│       ├── src/
│       │   ├── index.ts          # Public API: SDK functions, types, config
│       │   ├── config.ts         # configureClient() + JWT getter setup
│       │   └── client/           # Auto-generated on pnpm install (gitignored)
│       └── package.json          # @dhc/api-client workspace package
├── src/                       # Existing SvelteKit app (unchanged)
├── supabase/
│   ├── functions/             # Deno edge functions (BEING MIGRATED to Oban)
│   ├── migrations/            # SQL migrations (FROZEN — no new ones)
│   └── tests/                 # pgTAP database tests
├── e2e/                       # Playwright E2E tests
├── docs/
│   ├── adr/                   # Architecture Decision Records
│   └── agents/                # Agent documentation
├── CONTEXT.md                 # Domain glossary & architecture
├── .mise.toml                 # Tool versions + task runner (replaces Makefile)
└── .mise.local.toml           # Local mise overrides (gitignored)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add DB mutation | `src/lib/server/services/` | CURRENT system — MUST use service layer |
| Add API endpoint | `src/routes/api/` | CURRENT system — uses `authorize()` |
| Add edge function | `supabase/functions/` | DEPRECATED — migrate to Oban instead |
| Add Supabase migration | `supabase/migrations/` | FROZEN — no new migrations |
| Add Phoenix Ecto context | `apps/phoenix/lib/dhc/<domain>/` | NEW — use Ecto schemas + changesets |
| Add Oban worker | `apps/phoenix/lib/dhc/<domain>/workers/` | NEW — use `Oban.Worker` |
| Add Phoenix API endpoint | `apps/phoenix/lib/dhc_web/controllers/` | NEW — write spec first, generate stub |
| Update OpenAPI spec | `apps/phoenix/priv/api/openapi.yaml` | NEW — spec is the contract |
| Add Stripe API endpoint | `apps/phoenix/dev/dhc/stripe/processor.ex` → add operation ID to `@allowed_operations` → `mise run stripe-gen` | NEW — generated from Stripe OpenAPI spec |
| Deploy Phoenix API | `fly.toml`, `apps/phoenix/Dockerfile`, `.github/workflows/deploy-phoenix-fly.yml`, `fnox.toml` | Fly.io release deploy; fnox + 1Password provide runtime secrets |
| Stripe API adapter | `apps/phoenix/lib/dhc/stripe/client.ex` | Hand-written Req HTTP adapter |
| Stripe sync worker | `apps/phoenix/lib/dhc/stripe_sync/` | NEW — scheduled Oban cron job |
| Stripe webhook handler | `apps/phoenix/lib/dhc/stripe_webhooks/` | NEW — Phoenix controller + Oban worker pipeline |
| Stripe signature verification | `apps/phoenix/lib/dhc/stripe/webhook.ex` | Hand-rolled HMAC-SHA256 verification via `Dhc.Stripe.Webhook` |
| Webhook raw body plug | `apps/phoenix/lib/dhc_web/cache_body_reader.ex` | Caches raw body in `conn.assigns[:raw_body]` for signature verification |
| Update OpenAPI spec | `apps/phoenix/priv/api/openapi.yaml` | NEW — spec is the contract |
| Regenerate full API contract | Run `mise run api-gen` from repo root | Runs `mix gen.controllers` then TS client generator. Fails fast if either step errors. See `docs/agents/commands.md`. |
| Generate controllers from spec | Run `mix gen.controllers` in `apps/phoenix` | Generates controller + JSON renderer + contract test per tag. REST mapping from HTTP method + path. `--force` overwrites all, `--force=<path>` overwrites specific file. |
| Generate TS client | Run `pnpm api-gen` (or `pnpm --filter @dhc/api-client api:generate`) | NEW — from OpenAPI spec via `@hey-api/openapi-ts`. Output: `packages/api-client/src/client/` (gitignored, auto-generated on `pnpm install` via postinstall). |
| Add E2E test | `e2e/` | Use helpers from `setupFunctions.ts` |
| Seed dev data | `apps/phoenix/dev/dev_seeds.ex` + `dev/mix/tasks/seed.*.ex` | Dev-only. `mise run seed-members [count]`, `seed-waitlist [count]`, `seed-committee [csv]`. Uses [fakerer](https://github.com/artkay/fakerer) (`:faker` OTP app, Hex `:fakerer`, dev-only dep). Rows created concurrently via `Task.async_stream`. Inserts go through Ecto schemas (`WaitlistEntry`, `UserProfile`, `MemberProfile`, `Dhc.Auth.UserRole`, `Dhc.Waitlist.WaitlistGuardian`). `auth.users` stays raw SQL (Supabase-owned). |
| Run Phoenix tests | `mise run phx-test` | Testcontainers-elixir starts the `db` profile of the root `docker-compose.yml` per run, migrates, runs tests, tears down. No `supabase start` needed. See ADR 0006. |
| Configure Sentry | `config/runtime.exs` (prod block) + `config/config.exs` + `lib/dhc/application.ex` | Set `SENTRY_DSN` env var; integrates Phoenix, Oban, Logger, OpenTelemetry tracing (Bandit/Phoenix/Ecto), and Sentry Logs |
| View ADRs | `docs/adr/` | Key architectural decisions |
| View domain glossary | `CONTEXT.md` | Domain language reference |

## MIGRATION NOTES

- **Database**: Ecto owns all schema changes. Supabase migrations frozen. Baseline migrations model current schema in Elixir code. Before first Phoenix/Fly release migration on an existing Supabase DB, run `bridge.sql` once to seed Ecto `schema_migrations` for the Supabase-backed baseline only; leave Oban/new cutover migrations pending. The bridge is mirrored into `supabase/seed.sql` so a local `pnpm supabase:reset` auto-seeds `schema_migrations` and leaves the DB ready for `mix ecto.migrate` (which then runs only the cutover migrations: `20260512000001` Oban + `20260611224011` pg_cron removal). The standalone `scripts/bridge.sql` remains for one-shot production use via `psql "$DATABASE_URL" -f scripts/bridge.sql`.
- **Baseline migration fixes**: The testcontainers harness (ADR 0006) was the first time the baseline Ecto migrations actually ran against a fresh DB. This surfaced and fixed several latent bugs in the initial `4e5430e1` migration set: (1) `20260512000004` used `add :id, :bigint, default: fragment("generated by default as identity")` — invalid SQL (`DEFAULT "generated..."`); replaced with raw `CREATE TABLE` using `GENERATED BY DEFAULT AS IDENTITY`. (2) `20260512000004` relied on `add :supabase_user_id, ..., unique: true` — but Ecto silently ignores `:unique` on `add/3` (only `:default`/`:null`/`:collation` are emitted); added an explicit `create unique_index(:user_profiles, [:supabase_user_id])` (required by the FK in `20260512000008`). (3) `20260512000006` and `20260512000008` created both a `unique_index` and a plain `index` on the same column — name collision; dropped the redundant plain indexes. (4) `20260512000006` and `20260512000010` seeded rows via raw `INSERT` missing `inserted_at`/`updated_at` (NOT NULL from `timestamps/1`); added `NOW(), NOW()`. (5) `20260512000007` indexed `:created_at` on `club_activity_interest`, which uses `timestamps/1` (so the column is `inserted_at`); fixed to `:inserted_at`. When porting more Supabase SQL migrations to Ecto, watch for these patterns.
- **Auth**: Supabase Auth stays forever. Phoenix validates Supabase JWT. SvelteKit forwards JWT to Phoenix.
- **RLS**: No new policies. Existing ones removed when PostgREST is disabled.
- **Queues**: pgmq → Oban. Big-bang per-queue cutover. Discord → Email → Announcements → Stripe → Bulk Invite.
- **API design**: Spec-first with OpenAPI. Custom Mix task generates Phoenix controller stubs. TypeScript client generated from spec.
- **PostgREST read migration**: Replace SvelteKit `supabase.from(...).select(...)` reads with domain-shaped Phoenix APIs, not table/view proxies. Track remaining call sites in `docs/agents/postgrest-read-migration.md`; first slice is Waitlist per ADR 0005.
- **Ecto schema inserts vs raw SQL**: The seed tasks and test fixtures insert via the Ecto schemas (`MemberProfile`, `UserProfile`, etc.), not `Repo.insert_all` with raw maps. Two gotchas surfaced by this: (1) `member_profiles.preferred_weapon` is a Postgres `preferred_weapon[]` enum array, but the schema declares it `{:array, :string}` — inserts work because Postgres implicitly casts `text[]` → `preferred_weapon[]` at the column boundary (no custom Ecto type needed). (2) `MemberProfile`'s `:utc_datetime` fields reject microseconds; any computed `DateTime` must be `DateTime.truncate(dt, :second)` before insert (Postgres `timestamptz` accepts microseconds, so the old raw SQL didn't need this).
- **Stripe API**: Generated from Stripe OpenAPI spec via `oapi_generator`. Custom processor allows only needed endpoints. Regenerate with `mise run stripe-gen`. Hand-written `Dhc.Stripe.Client` adapter delegates to `Req`. API version pinned in `:stripe_api_version` config (default `"2025-10-29.clover"`) and sent as `Stripe-Version` header — must match `src/lib/server/stripe.ts`.
- **Stripe webhooks**: Phoenix controller validates Stripe-Signature header (HMAC-SHA256 via `Dhc.Stripe.Webhook`) then enqueues `Dhc.StripeWebhooks.Worker`. Raw body required — `DhcWeb.CacheBodyReader` caches `conn.assigns[:raw_body]` before JSON parsing. Webhook signing secret via `STRIPE_WEBHOOK_SIGNING_SECRET` env var (supports list for rotation). Endpoint is unauthenticated (`POST /api/webhooks/stripe`).
- **`.remote.ts` files**: The swap point. Rewrite from `executeWithRLS()` to `fetch(apiClient)` per domain.
- **Test harness**: Phoenix tests are driven by testcontainers-elixir via the root `docker-compose.yml` (`db` profile only). No `supabase start` required. `test_helper.exs` owns the full lifecycle (`--no-start` alias stops Mix from auto-starting the app): start `:hackney` (testcontainers-elixir's Tesla adapter needs it; not in its extra_applications) → start compose `db` profile → read the dynamic host port via `ComposeEnvironment.get_service_port/3` → merge hostname/port into the static Repo config from `config/test.exs` → start `:ecto_sql`/`:postgrex` and run migrations under a throwaway Repo supervisor → stop it → `Application.ensure_all_started(:dhc)` (Oban's `verify_migrated!` passes because `oban_jobs` now exists) + `:bypass` → sandbox + ExUnit → `System.at_exit` stops the app then runs `docker compose down -v` (testcontainers-elixir defaults `remove_volumes: true`). Migrations run BEFORE the app, not after — ADR 0006 line 11 assumed the reverse, but Oban 2.23's `testing: :manual` still runs `verify_migrated!` at startup, so `oban_jobs` must exist first. `config/test.exs` reads `POSTGRES_PASSWORD`/`POSTGRES_DB` from the same `.env` that interpolates the compose `db` service (defaults to `postgres`/`postgres`). The `supabase/postgres:17.6.1.136` image ships the `auth` schema + `pg_jsonschema` as *available* (not installed); migration `20260512000002` runs `CREATE EXTENSION IF NOT EXISTS pg_jsonschema WITH SCHEMA extensions`. E2E still uses `supabase start` for now; the compose file's `supabase` profile (GoTrue/Kong/PostgREST) is reserved for a future E2E migration. See ADR 0006.

## CRITICAL PATTERNS

See [docs/agents/critical-patterns.md](docs/agents/critical-patterns.md).

## ANTI-PATTERNS (FORBIDDEN)

See [docs/agents/anti-patterns.md](docs/agents/anti-patterns.md).

## COMMANDS

See [docs/agents/commands.md](docs/agents/commands.md).

## TECH STACK

See [docs/agents/tech-stack.md](docs/agents/tech-stack.md).

## SERVICES & ROLES

See [docs/agents/services-and-roles.md](docs/agents/services-and-roles.md).

## NOTES

See [docs/agents/notes.md](docs/agents/notes.md).

## Agent skills

### Issue tracker

GitHub Issues (uses `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context monorepo with `CONTEXT.md` at root and `docs/adr/` for ADRs. See `docs/agents/domain.md`.

---

**See Also**: `CONTEXT.md`, `docs/adr/`, `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
