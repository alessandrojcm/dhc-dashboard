# Commands

All tasks are defined in `.mise.toml`. Run `mise tasks` to list them all.

## Setup

```bash
# First time: install all pinned tools (Node, Erlang, Elixir, pnpm)
mise install

# Activate mise in your shell (one-time, add to your shell rc)
eval "$(mise activate bash)"    # bash
eval "$(mise activate zsh)"     # zsh
mise activate fish | source     # fish
```

After activation, `node`, `elixir`, `mix`, `pnpm` etc. resolve to the versions pinned in `.mise.toml` on every `cd`.

## SvelteKit (`apps/web`)

```bash
# Dev (start in order)
docker compose up -d db mailpit   # 1. Start PostgreSQL + Mailpit (dev email catcher)
mise run phx-server               # 2. Phoenix API and Oban workers
mise run dev                      # 3. SvelteKit dev from apps/web

# Testing
mise run test-unit          # Vitest
mise run test-browser       # Vitest Browser Mode component tests in Chromium
STRIPE_SECRET_KEY=sk_test_... mise run test-e2e
                            # Playwright + real Stripe test mode; self-starts disposable PostgreSQL, Phoenix, and SvelteKit
mise run check              # Svelte type check (NOT raw tsc)

# Lint & format
mise run lint               # Oxlint (web Svelte/JS/TS + API client TS)
mise run format             # Auto-format with Oxfmt
```

Oxlint runs in both `apps/web` and `packages/api-client`; the generated API client
under `packages/api-client/src/client/` is ignored. Oxfmt remains scoped to `apps/web`.

Playwright starts its Phoenix and SvelteKit processes through the internal
`e2e-phoenix-server` and `e2e-web-server` mise tasks. Their task-local environment
is the source of truth for E2E server settings; do not duplicate those variables
in `playwright.config.ts` command strings.

## Dev email catching (Mailpit)

The compose file ships a `mailpit` service (`axllent/mailpit`). In dev, the
email worker (`Dhc.Email.Worker`) relays every email job to it over SMTP
instead of calling the Loops API — the raw payload (recipient, template name,
data variables) arrives as pretty-printed JSON, since only Loops can render
the real templates. Web UI at `http://localhost:8025`, SMTP on
`localhost:1025` (override with `MAILPIT_HOST`/`MAILPIT_PORT`). Messages are
in-memory and lost on container restart. A stopped Mailpit container is not an
error: delivery failures log a warning and the job still succeeds.

The E2E suite intentionally uses Stripe's real test API for invitation acceptance.
It fails before startup unless `STRIPE_SECRET_KEY` starts with `sk_test_`. The test
account must provide active `monthly_membership_fee` and `annual_membership_fee`
lookup-key prices; coupon tests create unique promotion fixtures and clean them up.
Never supply a live-mode key.

## Phoenix (in progress)

Phoenix mise tasks override the root Supabase Docker `.env` database host and connect to host-local Supabase Postgres at `localhost:54322`.

```bash
# Setup (first time)
mise run phx-setup          # deps.get + ecto.create + ecto.migrate

# Server
mise run phx-server         # Start dev server (hot-reload) on :4000
mise run phx-console        # Start server inside IEx interactive shell

# Database
mise run phx-migrate        # Run pending migrations
mise run phx-rollback       # Rollback last migration
mise run phx-gen-migration NAME  # Generate a new migration
```

### One-off Discord roster export and assignment review

Export the existing guild roster once with Node's built-in `fetch`. The bot token
and guild ID come only from the process environment. The script writes
`roster.json` with mode `0600`; keep it restricted and delete it after the
migration review window.

```bash
DISCORD_BOT_TOKEN=... \
DISCORD_GUILD_ID=... \
node scripts/discord-roster-export.mjs

# Stage rows are a plain JSON array of
# {"principal_id":"...","discord_user_id":"...","username_snapshot":"..."}.
# The command prints the generated capture ID used by the later phases.
cd apps/phoenix
DISCORD_SUBJECT_FINGERPRINT_KEY=... \
mix dhc.discord.assignments stage ../../roster.json /secure/path/stage-rows.json PREPARER_PRINCIPAL_ID

# Review displays the selected roster evidence. Apply-review consumes a plain
# array of {"assignment_id":"...","decision":"approve|reject"}.
mix dhc.discord.assignments review CAPTURE_ID ../../roster.json REVIEWER_PRINCIPAL_ID
DISCORD_SUBJECT_FINGERPRINT_KEY=... \
mix dhc.discord.assignments apply-review CAPTURE_ID /secure/path/review-rows.json REVIEWER_PRINCIPAL_ID

DISCORD_SUBJECT_FINGERPRINT_KEY=... \
mix dhc.discord.assignments report CAPTURE_ID ../../roster.json
```

The separately authenticated operator supplies the preparer and reviewer IDs;
the task authorizes both against current Member-admin roles in the database, and
they must be different. The ID arguments are not authentication credentials.
The roster exporter is throwaway migration tooling, not a recurring sync or
Phoenix runtime task.

# Code quality
mise run phx-format         # Format all Elixir files
mise run phx-format-check   # Check formatting (CI)
mise run phx-precommit      # Full check: compile + deps.unlock + format + test

# Testing
mise run phx-test           # Run all Phoenix tests (excludes :integration tests)

# For specific test files, run directly:
cd apps/phoenix && mix test test/some_test.exs
cd apps/phoenix && mix test --failed     # Re-run only failed tests
cd apps/phoenix && mix ecto.migrations   # Show migration status

# Integration tests are excluded by default. Run with:
cd apps/phoenix && mix test --include integration
cd apps/phoenix && mix test test/dhc/stripe_sync/workers/worker_integration_test.exs --include integration

# Stripe sync integration test hits Stripe test mode and creates its own
# customers/subscriptions. Required: STRIPE_SECRET_KEY. STRIPE_SYNC_TEST_PRICE_ID
# is optional when lookup_key=standard_membership_fee exists in Stripe test mode.
cd apps/phoenix && \
  STRIPE_SECRET_KEY=sk_test_... \
  STRIPE_SYNC_TEST_PRICE_ID=price_... \
  mix test test/dhc/stripe_sync/workers/worker_integration_test.exs --include integration
```

Tests that use `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` commit outside the
per-test sandbox transaction and must explicitly delete every durable fixture
in `on_exit/1`. If teardown must remove immutable ALE-217 assignment audit rows,
disable only `ale217_reject_audit_mutation` for that deletion and always
re-enable it in an `after` block.

### Sentry (production error tracking)

Sentry activates automatically when `SENTRY_DSN` env var is set. Inactive otherwise.

```bash
# Enable Sentry (set this in production)
export SENTRY_DSN="https://your-dsn@sentry.io/your-project-id"
```

Sentry captures:
- Unhandled exceptions in HTTP requests (via `Sentry.PlugContext`)
- Failed Oban jobs (via Oban integration)
- `Logger.error/1` calls and process crashes (via `Sentry.LoggerHandler`)
- Oban cron check-ins (optional, for cron monitoring)

### Fly.io deployment (Phoenix API)

Phoenix deploys to Fly.io as an Elixir release built by `apps/phoenix/Dockerfile`, with `fly.toml` at the repo root.

```bash
# Required locally/CI: flyctl and FLY_API_TOKEN
mise run phx-fly-deploy        # fly deploy --depot (Fly Depot builder, persistent org-scoped layer cache)
```

The container runs Phoenix through `fnox exec --profile production -- /app/bin/dhc start`, and the Fly release command runs migrations through the same fnox profile. `fnox.toml` uses the `production` profile and 1Password vault `Production-phoenix-api`. Create one 1Password item per runtime env var (for example `DATABASE_URL`, `SECRET_KEY_BASE`, `STRIPE_SECRET_KEY`) with the value in the item's password field.

The only runtime bootstrap secret stored in Fly should be `OP_SERVICE_ACCOUNT_TOKEN`, scoped to the 1Password production vault:

```bash
fly secrets set OP_SERVICE_ACCOUNT_TOKEN=ops_... --app dhc-dashboard
```

Rotating app secrets in 1Password does not require `fly secrets set` or a new image; restart Machines to reload them through `fnox exec`. Only rotate the Fly secret when the 1Password service account token itself changes.

GitHub Actions workflow: `.github/workflows/deploy-phoenix-fly.yml`. Required GitHub secret: `FLY_API_TOKEN`. Optional GitHub variable: `FLY_PHOENIX_APP` (defaults to `dhc-dashboard`).

The workflow builds with `flyctl deploy --depot` (Fly's Depot builder), which provides persistent org-scoped Docker layer caching across builds. This is faster and more deterministic than `--remote-only`'s pooled builder, which may hand you a cold VM with no cache. The mise toolchain is installed inside the Dockerfile during the remote build, so the workflow does not install mise on the GitHub runner.

## API Contract (full pipeline)

Regenerate **both** sides of the API contract — Phoenix controller stubs and TypeScript client — in one step:

```bash
mise run api-gen
```

Fails fast: if either step exits non-zero, mise stops immediately and does not proceed.

**`mix gen.controllers` clobber caveat**: the task maps every operation under a tag to a REST action derived from HTTP method + path (or `operationId`), and regenerates the *whole* controller + JSON renderer + contract test for that tag. When a tag carries multiple non-REST operations (e.g. `Members` has `members.list`, `members.analytics`, `members.insuranceForm`), `--force=<path>` will overwrite the controller with stubs that map *all three* to `index` and call a non-existent `Members.list_members()` — clobbering any hand-written action bodies. After regenerating, restore the hand-written controller (keep your real action names + bodies) and never re-run `--force` on a tag whose controller you've fleshed out unless you're prepared to restore it from git. The JSON renderer and contract test are likewise tag-scoped, so extend them by hand for non-REST operations.

## API Client (TypeScript)

```bash
# Generate client from OpenAPI spec (from project root)
mise run api-gen

# Or run just the TS side
pnpm api-gen

# Watch mode (regenerate on spec changes)
pnpm --filter @dhc/api-client api:generate:watch
```

Generated output: `packages/api-client/src/client/` (gitignored — auto-regenerated on `pnpm install` via postinstall, do not manually edit)

**Manual step after `mise run api-gen`**: `packages/api-client/src/index.ts` is hand-maintained (tracked, not generated). `openapi-ts` only writes to `src/client/`; it does not update the public re-exports in `src/index.ts`. After adding a new operation, manually add the generated SDK function plus its `types.gen` / `valibot.gen` / `@tanstack/svelte-query.gen` exports to the four `export` blocks in `src/index.ts` (mirror how `waitlistStatus` / `membersInsuranceForm` are exposed). Without this, the function exists in `src/client/` but is not importable from `@dhc/api-client`.

`packages/api-client/openapi-ts.config.ts` explicitly points `output.tsConfigPath` at `packages/api-client/tsconfig.json` so postinstall generation works in deployment environments that do not expose the repo-root SvelteKit `tsconfig.json`.

`@hey-api/openapi-ts` + Valibot currently emits invalid TypeScript for boolean schemas expressed as `enum: [true]`/`enum: [false]` (it generates `v.picklist([true])`, but Valibot picklists are typed for string/number/bigint). For response flags that are always true on success, use `type: boolean` plus a description instead of a single-value boolean enum.

Usage in SvelteKit:
```ts
import { configureClient, healthIndex } from '@dhc/api-client';

// Configure once at app startup (e.g., +layout.svelte or hooks)
configureClient({
  baseUrl: 'http://localhost:4000/api',
  getAuthToken: async () => {
    const { data } = await supabase.auth.getSession();
    return data.session?.access_token;
  },
});

// Then use SDK functions
const { data, error } = await healthIndex();
```

## Stripe API Client (Elixir, generated)

```bash
# Regenerate from Stripe OpenAPI spec (downloads spec, trims, generates)
mise run stripe-gen
```

Generated output: `apps/phoenix/lib/dhc/stripe/generated/` (committed so production builds do not need to regenerate it; do not manually edit).

To add new Stripe endpoints:
1. Add the operation ID to `@allowed_operations` in `apps/phoenix/lib/mix/tasks/stripe.gen.ex`
2. Also add it to `@allowed_operations` in `apps/phoenix/dev/dhc/stripe/processor.ex` (the oapi_generator filter)
3. Run `mise run stripe-gen` (or `cd apps/phoenix && MIX_ENV=dev mix stripe.gen`)
4. Commit the regenerated output in `apps/phoenix/lib/dhc/stripe/generated/`
5. Use the generated functions via `Dhc.Stripe.Operations.*` with `Dhc.Stripe.Client`

- Do not hand-roll Stripe endpoint calls with `Dhc.Stripe.Client.request/1` in domain code. If an endpoint exists in Stripe's OpenAPI spec, find the operation ID by the Stripe URL, add that exact ID to both allow-lists above, regenerate, and call the generated `Dhc.Stripe.Operations.*` function. If generation still fails after both allow-lists match the current spec, debug the generator/filter rather than bypassing it.

Hand-written modules: `Dhc.Stripe.Client` (Req adapter), `Dhc.Stripe.Processor` (allowlist filter), `Dhc.StripeSync` (sync business logic), `Dhc.StripeSync.Worker` (Oban worker).

The Stripe API version is pinned in app config (`:stripe_api_version`, default `"2025-10-29.clover"`) and sent as the `Stripe-Version` header on every request. This matches the version used by the existing Deno edge functions (`src/lib/server/stripe.ts`). When updating, change the config value in all three env configs (`config.exs`, `dev.exs`, `test.exs`, `runtime.exs`), update `src/lib/server/stripe.ts`, and re-run `mise run stripe-gen`.

## Seeds

```bash
# Phoenix Mix tasks replacing legacy scripts/seed*.js
mise run seed-waitlist
mise run seed-waitlist 50
mise run seed-members
mise run seed-members 25
mise run seed-committee
mise run seed-committee ./scripts/users.csv

# Or run directly from Phoenix app
cd apps/phoenix && mix seed.waitlist 50
cd apps/phoenix && mix seed.members 25
cd apps/phoenix && mix seed.committee_members ../../scripts/users.csv
```

`mise` loads `.env` automatically; the seed Mix tasks do not load dotenv themselves. Keep `.env` up to date with the same Phoenix DB connection convention used by the app (`DATABASE_URL`, preferred). `seed.members`, `seed.workshops`, and `seed.committee_members` create Phoenix Principals directly through `Dhc.Auth`. `seed.members` only creates Stripe customers when `STRIPE_SECRET_KEY` is set. The committee CSV is intentionally local and gitignored because it contains member data; pass its path explicitly when `scripts/users.csv` is not present.

## CI (full check)

```bash
mise run ci                 # lint + format-check + type-check + unit tests
```
