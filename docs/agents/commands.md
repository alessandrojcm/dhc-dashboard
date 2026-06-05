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

## SvelteKit (current)

```bash
# Dev (start in order)
mise run sb-start           # 1. Start Supabase
mise run sb-functions       # 2. Edge functions
mise run dev                # 3. SvelteKit dev

# Database
mise run sb-types           # Generate Supabase TypeScript types
mise run sb-reset           # Reset + seed local DB

# Testing
mise run test-unit          # Vitest
mise run test-e2e           # Playwright (requires all 3 services)
mise run check              # Svelte type check (NOT raw tsc)

# Lint & format
mise run lint               # ESLint + Prettier check
mise run format             # Auto-format with Biome
```

## Phoenix (in progress)

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

# Code quality
mise run phx-format         # Format all Elixir files
mise run phx-format-check   # Check formatting (CI)
mise run phx-precommit      # Full check: compile + deps.unlock + format + test

# Testing
mise run phx-test           # Run all Phoenix tests

# For specific test files, run directly:
cd apps/phoenix && mix test test/some_test.exs
cd apps/phoenix && mix test --failed     # Re-run only failed tests
cd apps/phoenix && mix ecto.migrations   # Show migration status
```

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

## API Contract (full pipeline)

Regenerate **both** sides of the API contract — Phoenix controller stubs and TypeScript client — in one step:

```bash
mise run api-gen
```

Fails fast: if either step exits non-zero, mise stops immediately and does not proceed.

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

## Seeds

```bash
mise run seed-committee    # Seed committee members from CSV
mise run seed-waitlist     # Seed waitlist entries
mise run seed-members      # Seed member records
```

## CI (full check)

```bash
mise run ci                 # lint + format-check + type-check + unit tests
```