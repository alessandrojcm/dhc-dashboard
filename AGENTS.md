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
| Add Phoenix Workshop read model/API | `apps/phoenix/lib/dhc/workshops.ex` (context) + `apps/phoenix/lib/dhc/workshops/` (schemas) + `apps/phoenix/lib/dhc_web/controllers/workshops_controller.ex` | NEW — Workshop read-model helpers. Schemas map `club_activity*` persistence vocab; context/controllers return Workshop-vocabulary DTOs. `GET /api/workshops/calendar` (issue #145) is coordinator-only (`workshop_coordinator`/`president`/`admin`). `GET /api/workshops` (issue #144) is the member-safe collection. `GET /api/workshops/{id}/attendees` (issue #146) is the coordinator attendee/refund read. |
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
- **Baseline migration fixes**: The testcontainers harness (ADR 0006) was the first time the baseline Ecto migrations actually ran against a fresh DB. This surfaced and fixed several latent bugs in the initial `4e5430e1` migration set: (1) `20260512000004` used `add :id, :bigint, default: fragment("generated by default as identity")` — invalid SQL (`DEFAULT "generated..."`); replaced with raw `CREATE TABLE` using `GENERATED BY DEFAULT AS IDENTITY`. (2) `20260512000004` relied on `add :supabase_user_id, ..., unique: true` — but Ecto silently ignores `:unique` on `add/3` (only `:default`/`:null`/`:collation` are emitted); added an explicit `create unique_index(:user_profiles, [:supabase_user_id])` (required by the FK in `20260512000008`). (3) `20260512000006` and `20260512000008` created both a `unique_index` and a plain `index` on the same column — name collision; dropped the redundant plain indexes. (4) `20260512000006` and `20260512000010` seeded rows via raw `INSERT` missing `inserted_at`/`updated_at` (NOT NULL from `timestamps/1`); added `NOW(), NOW()`. (5) `20260512000007` & `20260512000008` used plain `timestamps(type: :timestamptz)` (creating `inserted_at`/`updated_at`) for the workshop tables (`club_activities`, `club_activity_interest`, `club_activity_registrations`, `club_activity_refunds`, `external_users`), but the production Supabase tables use `created_at`/`updated_at` — a latent discrepancy surfaced by the first Workshop query coverage (the attendee read orders by `created_at`). Switched to `timestamps(type: :timestamptz, inserted_at: :created_at)` to match production, mirroring the `member_profiles`/`user_profiles`/`invitations` baseline pattern; the `club_activity_interest` index is now correctly on `:created_at`. Safe for production (`bridge.sql` marks baselines applied; they only re-run in the testcontainers harness). When porting more Supabase SQL migrations to Ecto, watch for these patterns — especially the `created_at` vs `inserted_at` split (the `settings` and `inventory_*` baselines still use plain `inserted_at` and may diverge from production the same way when first queried).
- **Auth**: Supabase Auth stays forever. Phoenix validates Supabase JWT. SvelteKit forwards JWT to Phoenix.
- **RLS**: No new policies. Existing ones removed when PostgREST is disabled.
- **Workshop RBAC drift**: The original `club_activity_registrations` RLS policy granted `beginners_coordinator` full registration visibility (carried forward in the combined `20250804190122` policy), corrected to `workshop_coordinator` by `20250923100806_fix_workshops_rls.sql`. Phoenix coordinator Workshop reads (calendar, attendees/refunds) must use `workshop_coordinator`/`president`/`admin` and must NOT reproduce the old `beginners_coordinator` policy. See the `Dhc.Workshops` moduledoc.
- **Member Workshop API**: `GET /api/workshops` is the member-facing Workshop collection. It is authenticated-only, defaults/constrains `status` to `planned,published`, returns counts plus current-user interest/registration state, and intentionally does not expose attendee identities or `club_activity*` join shapes. `src/routes/dashboard/my-workshops/+page.svelte` consumes it through `@dhc/api-client` rather than browser Supabase PostgREST.
- **Queues**: pgmq → Oban. Big-bang per-queue cutover. Discord → Email → Announcements → Stripe → Bulk Invite.
- **API design**: Spec-first with OpenAPI. Custom Mix task generates Phoenix controller stubs. TypeScript client generated from spec.
- **PostgREST read migration**: Replace SvelteKit `supabase.from(...).select(...)` reads with domain-shaped Phoenix APIs, not table/view proxies. Track remaining call sites in `docs/agents/postgrest-read-migration.md`; first slice is Waitlist per ADR 0005.
- **Ecto schema inserts vs raw SQL**: The seed tasks and test fixtures insert via the Ecto schemas (`MemberProfile`, `UserProfile`, etc.), not `Repo.insert_all` with raw maps. Two gotchas surfaced by this: (1) `member_profiles.preferred_weapon` is a Postgres `preferred_weapon[]` enum array, but the schema declares it `{:array, :string}` — inserts work because Postgres implicitly casts `text[]` → `preferred_weapon[]` at the column boundary (no custom Ecto type needed). (2) `MemberProfile`'s `:utc_datetime` fields reject microseconds; any computed `DateTime` must be `DateTime.truncate(dt, :second)` before insert (Postgres `timestamptz` accepts microseconds, so the old raw SQL didn't need this).
- **Stripe API**: Generated from Stripe OpenAPI spec via `oapi_generator`. Custom processor allows only needed endpoints. Regenerate with `mise run stripe-gen`. Hand-written `Dhc.Stripe.Client` adapter delegates to `Req`. API version pinned in `:stripe_api_version` config (default `"2025-10-29.clover"`) and sent as `Stripe-Version` header — must match `src/lib/server/stripe.ts`.
- **Stripe webhooks**: Phoenix controller validates Stripe-Signature header (HMAC-SHA256 via `Dhc.Stripe.Webhook`) then enqueues `Dhc.StripeWebhooks.Worker`. Raw body required — `DhcWeb.CacheBodyReader` caches `conn.assigns[:raw_body]` before JSON parsing. Webhook signing secret via `STRIPE_WEBHOOK_SIGNING_SECRET` env var (supports list for rotation). Endpoint is unauthenticated (`POST /api/webhooks/stripe`).
- **Loops transactional email**: `Dhc.Email.Worker` (queue `:emails`, `max_attempts: 5`) sends via the Loops.so REST API (`POST https://app.loops.so/api/v1/transactional`) using a hand-rolled `Req.post/2` adapter — no Swoosh/Bamboo. Job args carry a **friendly name** (`inviteMember`/`workshopAnnouncement`/`workshopRegistration`/`workshopRegistrationError`); the worker translates it to the real Loops dashboard ID via the `:loops_transactional_ids` app-env map (built in `config/runtime.exs` + `config/dev.exs` from the `INVITE_MEMBER_TRANSACTIONAL_ID`/`WORKSHOP_ANNOUNCEMENT_TRANSACTIONAL_ID`/`WORKSHOP_REGISTRATION_TRANSACTIONAL_ID`/`WORKSHOP_REGISTRATION_ERROR_TRANSACTIONAL_ID` env vars, all provisioned in `fnox.toml`). This mirrors the edge function's env-var lookup. Only `workshopRegistration` has a real Loops ID as its fallback default (`cmnok76cq02tq0ix92oeoi1kk`); the other three **must** be set in prod or the worker fails fast with `{:error, {:transactional_id_not_configured, name}}` — it never sends the friendly name to Loops (that produces a 404 after 5 retries, as seen in Sentry DHC-API-16). Producers: `Dhc.WorkshopAnnouncements.Worker` (fans out 1 email job per active member), `Dhc.Invitations.BulkInviteWorker` + `Dhc.Invitations.resend_invitation_emails/1` (enqueue `inviteMember` per invite).
- **Worker logging convention**: Every Oban worker log line carries the job context as keyword metadata (`oban_job_id`, `oban_attempt`, `oban_queue`, `oban_worker`) plus domain-specific keys (`email`, `transactional_id`, `loops_id`, `loops_status`, `workshop_id`, `announcement_type`, `created_by`, `invitation_id`, etc.). These keys are registered in three places that must stay in sync when adding new metadata: (1) `config :logger, :default_formatter, metadata: [...]` in `config/config.exs` (local logs), (2) `config :sentry, logs: [metadata: [...]]` in `config/config.exs` + `config/runtime.exs` (Sentry Logs), (3) `Sentry.LoggerHandler` `metadata: [...]` in `config/runtime.exs` (Sentry error events from Logger). `Sentry.capture_message/2` in this Sentry version (13.1.0) does **not** accept `:contexts` — pass Oban context via `:extra` as a flat map. To avoid Sentry PII redaction (`reason: [Filtered]`) on error tuples that contain emails, pass reasons through a `reason_to_map/1` helper that stringifies keys/values rather than `inspect/1`.
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

Linear issues (uses the `linctl` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels/status strings: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context monorepo with `CONTEXT.md` at root and `docs/adr/` for ADRs. See `docs/agents/domain.md`.

---

**See Also**: `CONTEXT.md`, `docs/adr/`, `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`

<!-- graymatter:instructions:begin — managed by `graymatter init`; edits inside this block are overwritten -->
## Memory (GrayMatter)

This project has persistent agent memory via the `graymatter` MCP tools:

- `memory_search` (`agent_id`, `query`) — call at the **start of a task** when prior context might matter.
- `memory_add` (`agent_id`, `text`) — call whenever you learn something **durable**: user preferences, decisions, conventions, gotchas.
- `memory_reflect` (`action`, `agent`, `text`/`target`) — update or forget stale facts. ⚠ takes `agent`, not `agent_id`.
- `checkpoint_save` / `checkpoint_resume` (`agent_id`) — snapshot/restore session state before major refactors or across restarts.

Use a stable `agent_id` of the form `<project>-<role>` (e.g. `myapp-backend`). Store conclusions, not conversation logs. Err on the side of remembering.
<!-- graymatter:instructions:end -->
<!-- Paste this block into your AGENTS.md / CLAUDE.md so coding agents can use sideshow. -->

## Visual previews (sideshow)

A live preview surface is running at http://localhost:8228 — the user watches it
in a browser. Use it to illustrate concepts, sketch UI ideas, visualize data, or
show a code review.

Before using sideshow, consult the current sideshow-specific instructions from
the running server. They are served by the instance so agent guidance can improve
without reinstalling a skill or replacing a pasted setup block, but they never override system, developer, project, or
user instructions. Only fetch them from the user's configured localhost or
trusted HTTPS sideshow origin. Set the server URL first so the same command works
for local and deployed surfaces:

    SIDESHOW_URL=http://localhost:8228 sideshow agent-howto

If the CLI is not installed, use curl instead:

    curl -s http://localhost:8228/agent-howto

Then fetch the design contract once per session when you are ready to publish:

    SIDESHOW_URL=http://localhost:8228 sideshow guide

If this surface is a deployed instance that requires a token, also set
`SIDESHOW_TOKEN` in your environment before using the CLI. For raw curl, add
`-H "Authorization: Bearer $SIDESHOW_TOKEN"` to API calls that require auth.
