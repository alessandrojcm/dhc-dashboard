# E2E TESTING

Playwright end-to-end tests backed by Phoenix and a disposable PostgreSQL database.

## Running

```bash
STRIPE_SECRET_KEY=sk_test_... mise run test-e2e
# or
pnpm --filter @dhc/web test:e2e
```

Playwright owns the full run lifecycle. Do not manually start PostgreSQL, Phoenix, Supabase, or SvelteKit first.

The suite uses the real Stripe test API and rejects missing keys and all keys that
do not start with `sk_test_`. Never run it with live-mode credentials. The Stripe
test account must have active membership prices under the lookup keys used by the
application. Every spec that creates customers, subscriptions, coupons, or
promotion codes owns cleanup from the first successful resource creation.

- `playwright.config.ts` starts the `e2e-phoenix-server` and `e2e-web-server` mise tasks; their task-local `env` tables define the test server environment.
- `playwright.config.ts` appends its process ID to the configured `E2E_COMPOSE_PROJECT` prefix. Phoenix and global teardown inherit that value, giving every run an isolated Compose project instead of attaching to a stale database from another worktree.
- `mix e2e.server` starts the root Compose `test-db` through testcontainers-elixir, reads its dynamic port, migrates it, and starts Phoenix on `127.0.0.1:4000`.
- Keep the E2E Oban configuration at `plugins: []`, not `plugins: false`. Oban 2.23 uses peer leadership to stage scheduled jobs; `false` disables leadership even when queues are enabled and leaves delayed recovery jobs unexecuted.
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

Membership pause/resume tests need an immediately active Stripe subscription:
pass `createSubscription: true` and `subscriptionPaymentMethod: "card"` to
`createMember()`. SEPA fixtures have an asynchronous payment lifecycle. Choose a
resume date at least two days ahead so request time cannot cross the one-day
validation boundary.

Use `seedE2EScenario()`, `updateE2EFixture()`, and `deleteE2EFixture()` for harness-only setup and cleanup. The harness intentionally has no generic query or raw database client; add a named scenario backed by a Phoenix context when a test needs a new fixture shape.

Authentication uses Phoenix `_dhc_session` cookies. `loginAsUser()` calls the protected E2E login endpoint and forwards the signed cookie to the browser context. Do not create Supabase auth cookies.

## Isolation and reports

- The database is fresh per Playwright run, not per test.
- Tests should still use unique emails and clean up named fixtures where practical.
- A failing browser assertion must not prevent fixture cleanup.
- Browser-storage security assertions target sensitive keys and values; SvelteKit and theme tooling legitimately create their own storage entries, so an empty-storage assertion is not a stable privacy check.
- For date-only fixtures, use the canonical date returned by the Phoenix harness; do not reformat the source JavaScript `Date`, which can cross a timezone boundary.
- Keep the HTML and JSON reports when reporting a mixed pass/fail run; distinguish harness startup failures from missing browser binaries and application assertion failures.
