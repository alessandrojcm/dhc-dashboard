# E2E TESTING

Playwright end-to-end tests backed by Phoenix and a disposable PostgreSQL database.

## Running

```bash
mise run test-e2e
# or
pnpm --filter @dhc/web test:e2e
```

Playwright owns the full run lifecycle. Do not manually start PostgreSQL, Phoenix, Supabase, or SvelteKit first.

- `playwright.config.ts` starts the `e2e-phoenix-server` and `e2e-web-server` mise tasks; their task-local `env` tables define the test server environment.
- `mix e2e.server` starts the root Compose `test-db` through testcontainers-elixir, reads its dynamic port, migrates it, and starts Phoenix on `127.0.0.1:4000`.
- Global setup calls `POST /api/e2e/reset`, truncating application tables and restoring base settings.
- The suite currently uses one Playwright worker because legacy specs share run-level state. Add worker-partitioned databases before raising `workers`.
- HTML output is written to `apps/web/playwright-report`; machine-readable output is `apps/web/test-results/playwright-results.json`.

Docker and the Playwright Chromium/Firefox binaries are required. Install browsers with `pnpm --filter @dhc/web exec playwright install chromium firefox`.

## Phoenix test harness

The `/api/e2e/*` routes exist only when Phoenix compiles with `E2E_SERVER=true` under `MIX_ENV=test`. Every request requires the `x-e2e-harness-key` header. Never expose these routes in dev or production.

Use helpers from `setupFunctions.ts` for named domain fixtures:

- `createMember()`
- `setupWaitlistedUser()`
- `setupInvitedUser()`
- `createWorkshop()`

Use `seedE2EScenario()`, `updateE2EFixture()`, and `deleteE2EFixture()` for harness-only setup and cleanup. The harness intentionally has no generic query or raw database client; add a named scenario backed by a Phoenix context when a test needs a new fixture shape.

Authentication uses Phoenix `_dhc_session` cookies. `loginAsUser()` calls the protected E2E login endpoint and forwards the signed cookie to the browser context. Do not create Supabase auth cookies.

## Isolation and reports

- The database is fresh per Playwright run, not per test.
- Tests should still use unique emails and clean up named fixtures where practical.
- A failing browser assertion must not prevent fixture cleanup.
- Keep the HTML and JSON reports when reporting a mixed pass/fail run; distinguish harness startup failures from missing browser binaries and application assertion failures.
