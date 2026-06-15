# Commands

## SvelteKit (current)

```bash
# Dev (start in order)
pnpm supabase:start        # 1. Start Supabase
pnpm supabase:functions:serve  # 2. Edge functions
pnpm dev                   # 3. SvelteKit dev

# Database
pnpm supabase:types        # Generate types after schema changes
pnpm supabase:reset        # Reset + seed local DB

# Testing
pnpm test:unit             # Vitest
pnpm test:e2e              # Playwright (requires all 3 services)
pnpm check                 # Svelte type check (NOT raw tsc)
```

## Phoenix (in progress)

```bash
# All commands run from apps/phoenix/
cd apps/phoenix

# Setup (first time)
mix deps.get               # Install Elixir dependencies
mix ecto.create            # Create database
mix ecto.migrate           # Run pending migrations
mix setup                  # Shorthand: deps.get + ecto.create + ecto.migrate

# Server
mix phx.server             # Start dev server (hot-reload) on :4000
iex -S mix phx.server      # Start server inside IEx interactive shell

# Database
mix ecto.migrations        # Show migration status (up/down)
mix ecto.gen.migration description  # Generate a new migration
mix ecto.rollback          # Rollback last migration
mix ecto.rollback --step 3 # Rollback 3 migrations

# Code quality
mix format                 # Format all Elixir files
mix format --check-formatted  # Check formatting (CI)
mix compile                 # Compile project
mix precommit              # Full check: compile + deps.unlock + format + test

# Testing
mix test                   # Run all tests
mix test test/some_test.exs  # Run specific test file
mix test --failed          # Re-run only failed tests
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
