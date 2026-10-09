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
```

- The SvelteKit dev server serves **HTTPS** at the canonical local origin `https://127.0.0.1:5173` (`vite-plugin-mkcert`, self-signed). Probe it with `curl -sk https://127.0.0.1:5173/...`; plain `http://` curls fail even when the server is up. Keep frontend URLs, redirects, and browser visits on `127.0.0.1` rather than mixing it with `localhost`, because host-only auth cookies do not cross between them.
- Phoenix remains on `http://127.0.0.1:4000` in development. Since the browser frontend and API use different schemes, development auth cookies are intentionally `Secure; SameSite=None` and browser API calls use credentialed CORS. E2E remains a separate HTTP-only `127.0.0.1` topology with `SameSite=Lax` cookies.
- Invitation onboarding skips the external Discord authorization screen in development and returns through the normal callback automatically. Set `DISCORD_DEV_BYPASS=false` on `mise run phx-server` when manually testing the real Discord OAuth integration; sign-in and account-linking OAuth are never bypassed.
- If the Phoenix log shows `Phoenix.Ecto.PendingMigrationError`, every API request fails, including magic-link requests, which then send no email. Run `mise run phx-migrate`.
- **Agent smoke tests of dashboard pages:** the local dev DB has role accounts `admin@example.com`, `beginners@example.com` (beginners_coordinator, coach) and `president@example.com`. Request a magic link on `/auth`. The Mailpit message's `Text` is the JSON summary, so read `data_variables.LOGIN_LINK` from `GET http://127.0.0.1:8025/api/v1/message/<id>`. Magic links are rate-limited per email and per IP, so save Playwright `storageState` after the first login and reuse it. To stay out of the user's Chrome, drive `apps/web/node_modules/playwright` (Chromium is already installed for E2E) from a scratch `.mjs` outside the repo with `ignoreHTTPSErrors: true`, run via `mise exec -- node`.
- Unhandled server errors are console-logged (status, method, path, route, stack) by `logUnhandledServerError` in `apps/web/src/hooks.server.ts`, wrapped inside Sentry's `handleError`. The catch-all UI is the root `apps/web/src/routes/+error.svelte` plus `apps/web/src/error.html` (fallback for errors in `handle`, `+server.js`, or the root layout load, which no `+error.svelte` can render).

```bash

# Testing
mise run test-unit          # Vitest
mise run test-browser       # Vitest Browser Mode component tests in Chromium
STRIPE_SECRET_KEY=sk_test_... mise run test-e2e
                            # Playwright + real Stripe test mode; self-starts disposable PostgreSQL, Phoenix, and SvelteKit
mise run check              # svelte-check over src/ + tsc over e2e/ (pnpm check:e2e); NOT raw tsc on src

# Lint & format
mise run lint               # Oxlint (web Svelte/JS/TS + API client TS)
mise run format             # Auto-format with Oxfmt
```

**herdr panes in this repo run `fish`, not `zsh`.** `(...)` is command
substitution and `$?` does not exist there, so a chained gate written as
`(mise run check && mise run lint) ...; echo $?` fails to parse — and the
rejected text stays on the prompt, silently swallowing the next command you
send. Put multi-step or exit-code-checking runs in a `#!/bin/zsh` script under
the approved temp dir and have the pane execute that file. `mix` is also not on
the pane's PATH; prefix it with `mise exec --`. If a pane starts echoing your
command back instead of running it, clear the stuck prompt with
`herdr pane send-keys <id> ctrl+c` then `ctrl+u`.

In a fresh linked worktree, run `mise run check` before `mise run lint` or
`mise run ci`. The check runs `svelte-kit sync` and creates
`apps/web/.svelte-kit/tsconfig.json`; without it, Oxlint can fail while loading
the web TypeScript project, and the parallel `ci` tasks cannot reliably create
the file before lint starts.

Oxlint runs in `apps/web`, `packages/api-client`, and `packages/email-templates`;
the generated API client under `packages/api-client/src/client/` is ignored.
Oxfmt covers `apps/web` and `packages/email-templates`.
The shared config loads the project-local anti-slop plugin from
`tools/oxlint/anti-slop/`; keep `oxlint` and `@oxlint/plugins` on the same pinned
version when upgrading it, and leave all anti-slop rules enabled at error severity.

Playwright starts its Phoenix and SvelteKit processes through the internal
`e2e-phoenix-server` and `e2e-web-server` mise tasks. Their task-local environment
is the source of truth for E2E server settings; do not duplicate those variables
in `playwright.config.ts` command strings.

## Dev email catching (Mailpit)

The compose file ships a `mailpit` service (`axllent/mailpit`). In dev, the
email worker (`Dhc.Email.Worker`) delivers through Swoosh's Mailpit **HTTP**
adapter (ADR 0021): each job arrives as a real message whose body is the
pretty-printed JSON summary (recipient, friendly template name, data
variables), since only the provider can render the real templates. Web UI at
`http://localhost:8025` (override with `MAILPIT_HTTP_URL`; the SMTP port 1025
is no longer used). Messages are in-memory and lost on container restart. A
stopped Mailpit container is not an error: delivery failures log a warning and
the job still succeeds.

The E2E suite intentionally uses Stripe's real test API for invitation acceptance.
It fails before startup unless `STRIPE_SECRET_KEY` starts with `sk_test_`. The test
account must provide active `monthly_membership_fee` and `annual_membership_fee`
lookup-key prices; coupon tests create unique promotion fixtures and clean them up.
Never supply a live-mode key.

## Email templates (Resend sync)

The transactional templates are React Email components in
`packages/email-templates`, synced upsert-by-alias to Resend-hosted templates
(ADR 0022). See that package's README for the drift policy and CI wiring.

- When adding a rendered template variable, update the component metadata and
  the explicit prop mapping in `scripts/sync.tsx`; the upload renderer must
  preserve its `{{{VARIABLE}}}` marker. Invitation issue and resend jobs read
  the insurance URL through `Dhc.Members.insurance_form/0` and supply
  `INSURANCE_FORM_LINK`; an unconfigured value is omitted for the template fallback.

```bash
mise run email-sync          # render + upsert drafts (what PRs do)
mise run email-sync-publish  # upsert + publish (what merge-to-main does)
mise run email-smoke         # fail unless every whitelisted kind has a published template
mise run email-shells        # generate Phoenix announcement HTML + styles (no Resend key)
pnpm --filter @dhc/email-templates verify:html-variable
                             # one real send to delivered@resend.dev: is {{{MESSAGE_HTML}}} inserted unescaped?
```

The sync, smoke and verify commands need a Full Access key as `RESEND_API_KEY` (`fnox` holds the send-only
key under that name in the `production` profile, read through the 1Password `op` CLI with the desktop app integration turned on; use the `RESEND_API_KEY_CI` value, a GitHub Actions secret that fnox does not hold, for syncs and the verify send). The GitHub
Actions workflow `.github/workflows/email-templates.yml` runs the same pipeline:
drafts on pull requests, publish + smoke on main, gated by change detection on
`packages/email-templates/**`.

Template assets (the crest) are served from the R2 bucket `dhc-email-assets`
at `https://assets.dublinhemaclub.com`, decoupled from the web app. After
changing files in `packages/email-templates/emails/static/`, run
`mise run email-asset-upload` (needs `CLOUDFLARE_API_TOKEN` or an interactive
`wrangler login`; one-time bootstrap: create the bucket and attach its custom
domain).

## Phoenix (in progress)

Phoenix mise tasks override the root Supabase Docker `.env` database host and connect to host-local Supabase Postgres at `localhost:54322`.

```bash
# Setup (first time)
mise run phx-setup          # deps.get + ecto.create + ecto.migrate

# Server
mise run phx-server         # Start dev server (hot-reload) on :4000
mise run phx-console        # Start server inside IEx interactive shell

# Docker alternative (Phoenix + PostgreSQL + Mailpit; source hot-reloads)
mise run email-shells       # generate gitignored artifacts before Docker build
docker compose --profile phoenix up --build phoenix

# Database
mise run phx-migrate        # Run pending migrations
mise run phx-rollback       # Rollback last migration
mise run phx-gen-migration NAME  # Generate a new migration
```

The Compose `phoenix` profile uses `apps/phoenix/Dockerfile.dev`, bind-mounts
the Phoenix source, and leaves Mix dependencies/build artifacts in the image so
the source mount does not erase the dependency cache. It publishes Phoenix at
`http://127.0.0.1:4000`; stop it with `docker compose --profile phoenix down`.

Phoenix compilation embeds the generated `priv/email_shells` HTML and styles.
Phoenix mise tasks generate them automatically; before calling Mix or building
either Phoenix Dockerfile directly, run `mise run email-shells` from the root.
Fly CI generates on the runner before uploading the Docker context, so the
remote builder needs only Erlang/Elixir. Keep these artifacts in the Docker
context even though they are gitignored.

### One-off Discord roster export and assignment review

Export the existing guild roster once with `@discordjs/rest`, which handles
Discord rate limits while the script paginates through the guild. The bot token
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

### One-time Waitlist spreadsheet import (ALE-376)

Imports the club's Waitlist Google Forms export (CSV or TSV, header row as
exported) once. Always dry-run first: it validates every row against the
database and prints the full report (imported, refused with reasons, notes,
each row's Paid/Carried Fee value) without writing. A sheet with
month-first-only dates or a missing column is refused whole. Do not run it
against the shared dev database, and do not run it in production until
ALE-388 makes `Dhc.Waitlist.Import.create_carried_fee/2` create Carried Fees.

```bash
cd apps/phoenix
mix dhc.waitlist.import /secure/path/waitlist.tsv --dry-run
mix dhc.waitlist.import /secure/path/waitlist.tsv

# In a release (no Mix):
bin/dhc eval 'Dhc.Release.import_waitlist("/secure/path/waitlist.tsv", dry_run: true)'
bin/dhc eval 'Dhc.Release.import_waitlist("/secure/path/waitlist.tsv")'
```

# Code quality
mise run phx-format         # Format all Elixir files
mise run phx-format-check   # Check formatting (CI)
mise run phx-reach          # Reach architecture policy checks (.reach.exs)
mise run phx-precommit      # Full check: audit + credo + reach arch + compile + unlock + format + test

# Testing
mise run phx-test           # Generate the TS API client, then run all Phoenix tests (excludes :integration)

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
in `on_exit/1`. If teardown must remove immutable Discord assignment audit rows,
disable only `discord_assignment_reject_audit_mutation` for that deletion and
always re-enable it in an `after` block.

### Reach architecture policy (`apps/phoenix/.reach.exs`)

Reach (`mix reach.check --arch`, also in the `precommit` alias) enforces module-boundary rules Credo cannot express:

- Layers: `DhcWeb.*` / `Dhc.*` / `Dhc.Repo`; domain must not depend on web (except `DhcWeb.Endpoint` infrastructure edges), Repo must not depend on web, and the web layer must not touch the Repo directly (`DhcWeb.Plugs.MagicLinkRateLimit` is the one documented seam).
- Forbidden calls: `Dhc.Stripe.Client.request/1` outside the client itself (Stripe goes through generated `Dhc.Stripe.Operations.*`), any `Nostrum.*` outside `Dhc.Discord.*`, `HTTPoison`/`Tesla`/`:httpc` anywhere, and `IO.puts` outside Mix tasks and `Dhc.Release`.

Findings are fingerprinted against `.reach-baseline.json`. New findings fail the build; only baseline a known transitional finding with:

```bash
cd apps/phoenix && MIX_ENV=dev mix reach.check --arch --write-baseline .reach-baseline.json
```

The config pins `checks.source_paths: ["lib"]`, so one baseline stays valid across dev and test environments.

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

**`mix gen.controllers` scaffolds per slice**: the *slice* — the `operationId` prefix, e.g. `inventoryStructure` from `inventoryStructure.showDefinition` — names the controller, JSON renderer, and contract test. The *tag* remains the domain boundary ("one domain = one tag = one URL root") and supplies `x-context`/`x-resource`, so one tag can own several controllers. Give every operation an `operationId` of `<slice>.<action>` whose `<slice>` underscores to the controller filename; otherwise the generator writes a stub for a controller you did not intend.

Re-running is safe by default: a slice whose controller already exists is skipped **together with its renderer and test**, so `mise run api-gen` is idempotent and should print only `skip` lines for existing slices.

**`--force` clobber caveat**: `--force`/`--force=<path>` bypasses that skip and regenerates the whole trio from the spec, mapping operations to REST actions derived from HTTP method + path (or `operationId`). When a slice carries multiple non-REST operations (e.g. `members` has `members.list`, `members.analytics`, `members.insuranceForm`), it will overwrite the controller with stubs that map *all three* to `index` and call a non-existent `Members.list_members()` — clobbering hand-written action bodies. After forcing, restore the hand-written controller (keep your real action names + bodies), and never `--force` a slice you have fleshed out unless you can restore it from version control.

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

`@hey-api/openapi-ts` + Valibot currently emits invalid TypeScript for boolean schemas expressed as `enum: [true]`/`enum: [false]` (it generates `v.picklist([true])`, but Valibot picklists are typed for string/number/bigint). For response flags that are always true on success, use `type: boolean` plus a description instead of a single-value boolean enum. Nullable enums need the reverse care: the generator only honours the null when it is listed *inside* `enum` (e.g. `enum: [a, b, null]` with `nullable: true`) — a bare `nullable: true` beside an enum silently generates a non-nullable validator, which then rejects the real Phoenix response at runtime. The parity test pins the generated `v.nullable(v.picklist(...))` shape for every such field.

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
mise run seed-invitations
mise run seed-invitations 50
mise run seed-members
mise run seed-members 25
mise run seed-committee
mise run seed-committee ./scripts/users.csv
mise run seed-inventory
mise run seed-inventory 30
mise run seed-beginners-workshops
mise run seed-beginners-workshops 6

# Or run directly from Phoenix app
cd apps/phoenix && mix seed.waitlist 50
cd apps/phoenix && mix seed.invitations 50
cd apps/phoenix && mix seed.members 25
cd apps/phoenix && mix seed.committee_members ../../scripts/users.csv
cd apps/phoenix && mix seed.inventory 30
```

`mise` loads `.env` automatically; the seed Mix tasks do not load dotenv themselves. An exported `DATABASE_URL` does **not** override `.env` under `mise exec`/`mise run` — every linked worktree's `.env` points at the shared local dev DB. To migrate or seed a throwaway database, pass it inside the command: `mise exec -- env DATABASE_URL=postgres://… mix ecto.migrate`. Keep `.env` up to date with the same Phoenix DB connection convention used by the app (`DATABASE_URL`, preferred). `seed.members`, `seed.workshops`, and `seed.committee_members` create Phoenix Principals directly through `Dhc.Auth`. `seed.invitations` creates direct, pending member invitations without a waitlist entry or an issuing administrator. `seed.members` only creates Stripe customers when `STRIPE_SECRET_KEY` is set. `seed.beginners_workshops` schedules workshops through the `Dhc.BeginnersWorkshops` boundary as `beginners.seeder@example.com` (a beginners coordinator it creates), plus one workshop contacted from yesterday whose Batch 1 is sent through `send_due_batch` at yesterday's 10:00 Dublin, so it has an open Batch window (it seeds waiting Waitlist entries first when fewer than 8 are waiting, and queues their contact emails), plus (ALE-381) one more workshop contacted yesterday with 2 Intakes paid through `complete_payment` and 2 holding a live Seat Hold (their payment rows are written directly so the seed needs no Stripe key; the sweep's reaper frees those holds 30 minutes later); later tickets extend it with lifecycle stages. `seed.inventory` creates typed categories, nested containers, physical items, active members as needed, and a spread of available, maintenance, requested, approved, and checked-out states. The committee CSV is intentionally local and gitignored because it contains member data; pass its path explicitly when `scripts/users.csv` is not present.

## CI (full check)

```bash
mise run ci                 # lint + format-check + type-check + unit tests
```
