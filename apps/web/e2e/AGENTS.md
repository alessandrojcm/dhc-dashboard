# E2E TESTING

Playwright end-to-end tests backed by Phoenix and a disposable PostgreSQL database.

## Running

```bash
STRIPE_SECRET_KEY=sk_test_... mise run test-e2e
# or
pnpm --filter @dhc/web test:e2e
```

Playwright owns the full run lifecycle. Do not manually start PostgreSQL, Phoenix, Supabase, or SvelteKit first.

Run focused specs through the documented mise task (`mise run test-e2e --
e2e/example.spec.ts`), not a direct filtered workspace invocation, so the same
task environment and server lifecycle are used as full runs.

The suite uses the real Stripe test API and rejects missing keys and all keys that
do not start with `sk_test_`. Never run it with live-mode credentials. The Stripe
test account must have active membership prices under the lookup keys used by the
application. Every spec that creates customers, subscriptions, coupons, or
promotion codes owns cleanup from the first successful resource creation, except
durable account configuration explicitly shared with the application. The tier
signup spec creates missing `DHC_COACH_TIER` / `DHC_STUDENT_TIER` coupons and
retains them just like membership prices.

- `playwright.config.ts` starts the `e2e-phoenix-server` and `e2e-web-server` mise tasks; their task-local `env` tables define the test server environment.
- `playwright.config.ts` keeps `serviceWorkers: "block"`. The ALE-270 shell-caching worker re-issues same-origin requests from the worker, which bypasses `page.route` mocks (e.g. the Discord acceptance mock) without changing app behavior — every mocked-navigation test fails with the app working fine. Do not remove the block; the PWA shell spec asserts on static output only by design.
- `mix e2e.server` starts the application through a custom Mix task, so E2E-only Stripe coupon overrides are read in `config/test.exs` when `E2E_SERVER=true`; do not rely on production-only runtime configuration for the test server.
- `playwright.config.ts` appends its process ID to the configured `E2E_COMPOSE_PROJECT` prefix. Phoenix and global teardown inherit that value, giving every run an isolated Compose project instead of attaching to a stale database from another worktree.
- `mix e2e.server` starts the root Compose `test-db` through testcontainers-elixir, reads its dynamic port, migrates it, and starts Phoenix on `127.0.0.1:4000`.
- Keep the E2E Oban configuration at `plugins: []`, not `plugins: false`. Oban 2.23 uses peer leadership to stage scheduled jobs; `false` disables leadership even when queues are enabled and leaves delayed recovery jobs unexecuted.
- Global setup calls `POST /api/e2e/reset`, truncating application tables and restoring base settings.
- The suite currently uses one Playwright worker because legacy specs share run-level state. Add worker-partitioned databases before raising `workers`.
- HTML output is written to `apps/web/playwright-report`; machine-readable output is `apps/web/test-results/playwright-results.json`.

Docker and the Playwright Chromium/Firefox binaries are required. Install browsers with `pnpm --filter @dhc/web exec playwright install chromium firefox`.

On a macOS Docker VM (Colima, OrbStack, Lima, or Docker Desktop) the testcontainers harness needs the socket named on both sides, because the client and the container see different filesystems: `DOCKER_HOST` must be the client-side socket (e.g. `unix://$HOME/.colima/default/docker.sock`, since `DOCKER_HOST` is unset and `/var/run/docker.sock` is only a dangling symlink to Docker Desktop), and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` must be the VM-side path that `mix e2e.server` bind-mounts into the Postgres container. Without them the harness fails before any test runs, with `{:docker_socket_not_found, ...}` and then `error while creating mount source path ... operation not supported`.

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

- Beginners' Workshop scenarios (ALE-398) live in `apps/phoenix/test/support/e2e_harness/beginners_workshops.ex` and are named `beginnersWorkshop*` (the `seed/2` clause delegates by prefix): `beginnersWorkshop` (schedule through the boundary), `beginnersWorkshopBatch` (the Batch pass at a fixed 10:00 Dublin today), `beginnersWorkshopIntakeLink` (the person's Intake page path, token included), `beginnersWorkshopPayment` (stands in for Stripe's hosted Checkout: completes the recorded Seat Hold through `complete_payment`), `beginnersWorkshopDoorOpen` (moves the workshop to today, starting now, so check-in is open) `beginnersWorkshopCarriedFee` (a `held` imported fee) and `beginnersWorkshopInvitation` (the Invitation the handoff issued; delete it with the `invitation` fixture, because `invitations-management.spec.ts` counts every Invitation in the run). A Batch takes the oldest `waiting` people first, so seed the person with an old `initialRegistrationDate` on the `waitlist` scenario and capacity 1, or the Batch contacts whoever else the run left waiting. Pay is asserted only as the redirect to a `cs_test_` Checkout URL; route `https://checkout.stripe.com/**` to a stub so Stripe's page never loads. The journey lives in `beginners-workshop-journey.spec.ts`.
- `reset!` truncates every table except `@kept_tables` (`schema_migrations` and `beginners_workshop_email_templates`, which only a migration seeds — without it every Batch fails with `Ecto.NoResultsError`, served as a 404). Keep any future migration-seeded reference table there too.
- The dev server's TanStack Query Devtools button covers the bottom-right corner and intercepts clicks on whatever sits there (e.g. an Invite button at a row's right edge). Press such a control from the keyboard (`focus()` + `Enter`) rather than forcing the click.
- `mise run check` runs svelte-check over `apps/web/src/` **and** `pnpm check:e2e` (`tsc -p e2e/tsconfig.json --noEmit`) over this directory, so harness union edits and spec type errors fail the check like any other type error. `e2e/tsconfig.json` inherits the SvelteKit compiler options and only replaces `include`; do not add e2e globs to the root `tsconfig.json`.

Authentication uses Phoenix `_dhc_session` cookies. `loginAsUser()` calls the protected E2E login endpoint and forwards the signed cookie to the browser context. Do not create Supabase auth cookies. Inactive principals cannot authenticate: always log in as an active operator fixture and treat inactive members as targets of admin actions, never as the signed-in user.

## Isolation and reports

- The database is fresh per Playwright run, not per test.
- Playwright swallows both web servers' stdout. To see Phoenix/SvelteKit logs (SQL, 4xx/5xx responses, stack traces) while reproducing a failure, prefix the run with `DEBUG=pw:webserver`, e.g. `DEBUG=pw:webserver STRIPE_SECRET_KEY=sk_test_... mise run test-e2e -- e2e/some.spec.ts -g "test name"`.
- Tests should still use unique emails and clean up named fixtures where practical.
- A failing browser assertion must not prevent fixture cleanup.
- Browser-storage security assertions target sensitive keys and values; SvelteKit and theme tooling legitimately create their own storage entries, so an empty-storage assertion is not a stable privacy check.
- For date-only fixtures, use the canonical date returned by the Phoenix harness (`fetchE2EStatus().today` / `addClubDays`); do not reformat the source JavaScript `Date`, which can cross a timezone boundary.
- Keep the HTML and JSON reports when reporting a mixed pass/fail run; distinguish harness startup failures from missing browser binaries and application assertion failures.
- The browser viewport is host-dependent (`viewport: null` + `--start-maximized`), so responsive layouts render either branch: member-directory assertions must match both the desktop table row and the mobile card (e.g. `getByRole("row").filter(...).or(getByRole("article").filter(...))`). Note that bare boolean attributes in Svelte templates are literal `true`, not variable shorthand — pass `prop={value}` explicitly.
- Root container names are globally unique: the E2E database is shared per run. `createInventoryStructure` randomises its default root (`E2E Cage <rand>`); still pass an explicit path when the spec asserts on the name. A hardcoded `"E2E Cage"` 422s on `containers_root_name_unique` the second time.
- Bits-ui v2 Select triggers expose no `combobox` role (plain button with `aria-haspopup="listbox"`): drive catalog filters via the trigger button's visible text (e.g. `getByRole("button", { name: "Everything" })`) and `option` roles.
- The QueryClient keeps TanStack defaults (queries retry 3× with backoff), so settled query-error assertions (e.g. 404 detail pages) need longer timeouts (15s), not the 5s expect default. Mutations do not retry.
- bits-ui `Tabs.Content` renders every panel and only marks inactive ones `hidden`, so on a tabbed page (e.g. `/dashboard/beginners-workshop`, whose Workshops, Invitable and Dashboard tabs each have tables) an unscoped `table tbody tr` also counts hidden tables' rows. Scope to the open panel with `page.getByRole("tabpanel", { name: "<tab label>" })`; its accessible name is set on hydration, so reach the page with `gotoHydrated`.
- Harness teardown refuses rather than raises: a fixture that history still names returns 409 `still_referenced` (member teardown adds the foreign key as `constraint`), and the transaction rolls back. A Principal the run made act (container creator, borrower, maintenance starter, Staff) can never be deleted, because those foreign keys keep history on purpose; the per-run database is disposable, so the member simply stays. Never let a harness request raise for an expected refusal: Bandit closes the keep-alive socket after a raised request, fetch reuses it for the next POST (it retries resets only for idempotent methods), and the _next_ spec's setup fails with `fetch failed … ECONNRESET` while its tests do not run. `DEBUG=pw:webserver` shows the 500 right before the reset.

## What specs may assert

- Assert what a user perceives: roles, accessible names, visible text, URLs, enabled/disabled state, ARIA state (`aria-pressed`, `aria-valuenow`, `aria-current`). Never assert CSS classes, computed styles (`toHaveCSS`), `data-*` attributes, element geometry (`boundingBox`), or DOM structure, and do not add production markup that only exists to be read by a spec (the one exception is the `data-app-hydrated` signal behind `gotoHydrated`, a wait rather than an assertion). `getByTestId` is acceptable as a locator of last resort, never as the thing asserted.
- When a visual or layout property is the contract (a full-screen mobile sheet, touch-target size), use `toHaveScreenshot` on content that is static across runs: set an explicit `page.setViewportSize`, and screenshot an element or page whose text does not include run-tagged fixture names or shared-run data. Baselines live in `e2e/<spec>-snapshots/` (darwin; E2E is not run in CI); create missing ones with `mise run test-e2e -- e2e/<spec>.spec.ts --update-snapshots=missing` (that pass reports each newly written baseline as a failure), rerun without the flag to confirm they match, and review the PNGs before committing. `e2e/screenshot.css` (wired as `expect.toHaveScreenshot.stylePath`) hides the TanStack Query Devtools button that the `pnpm dev` E2E server renders bottom-right; add any other dev-only overlay there rather than masking per test.
- Address the Stripe Payment Element through `e2e/stripe-payment.ts` (the iframe's accessible title, not Stripe's private wrapper class). Payment-step readiness is `signupSubmitButton(page)` becoming enabled; there is no hidden state element.
