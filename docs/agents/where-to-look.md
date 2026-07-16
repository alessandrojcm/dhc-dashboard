# Where to look

| Task | Location | Notes |
|------|----------|-------|
| Add DB mutation | `apps/phoenix/lib/dhc/<domain>/` | Phoenix is the current owner. The legacy Svelte service directory has been removed; do not recreate it. |
| Add API endpoint | `src/routes/api/` | CURRENT system — uses `authorize()` |
| Add edge function | `supabase/functions/` | DEPRECATED — migrate to Oban instead |
| Add Supabase migration | `supabase/migrations/` | FROZEN — no new migrations |
| Add Phoenix Ecto context | `apps/phoenix/lib/dhc/<domain>/` | NEW — use Ecto schemas + changesets |
| Add Phoenix Workshop model/API | `apps/phoenix/lib/dhc/workshops.ex` (context) + `apps/phoenix/lib/dhc/workshops/` (schemas) + `apps/phoenix/lib/dhc_web/controllers/workshops_controller.ex` | Phoenix owns all Workshop management, interest, registration, attendance, cancellation, and refund paths. SvelteKit must call these APIs through `@dhc/api-client`; the legacy Svelte workshop services have been removed. Schemas map `club_activity*` persistence vocab; context/controllers return Workshop-vocabulary DTOs. |
| Add Phoenix Inventory Category slice | `apps/phoenix/lib/dhc/inventory.ex` (context) + `apps/phoenix/lib/dhc/inventory/equipment_category.ex` (schema) + `apps/phoenix/lib/dhc/inventory/json_array.ex` (custom jsonb-array type) + `apps/phoenix/lib/dhc_web/controllers/inventory_categories_controller.ex` + `inventory_categories_json.ex` | NEW — ALE-105. Endpoints `GET/POST /api/inventory/categories` and `GET/PATCH/DELETE /api/inventory/categories/:id` follow the ALE-104 contract. Reads are any authenticated member (`:authenticated_api`); writes use the `:inventory_admin_api` pipeline. The Svelte pages consume `@dhc/api-client`; the legacy `CategoryService` has been removed. |
| Add Phoenix Inventory Container slice | `apps/phoenix/lib/dhc/inventory.ex` (container context fns) + `apps/phoenix/lib/dhc/inventory/container.ex` (Ecto schema) + `apps/phoenix/lib/dhc_web/controllers/inventory_containers_controller.ex` + `inventory_containers_json.ex` | NEW — ALE-106. Endpoints `GET/POST /api/inventory/containers` and `GET/PATCH/DELETE /api/inventory/containers/:id` follow the ALE-104 contract. Reads use `:authenticated_api`; writes use `:inventory_admin_api`. The Svelte pages consume `@dhc/api-client`; the legacy `ContainerService` has been removed. |
| Add Phoenix Inventory Item slice | `apps/phoenix/lib/dhc/inventory.ex` (item + history context fns) + `apps/phoenix/lib/dhc/inventory/item.ex` + `apps/phoenix/lib/dhc/inventory/inventory_history.ex` + `apps/phoenix/lib/dhc_web/controllers/inventory_items_controller.ex` + `inventory_items_json.ex` | NEW — ALE-107/ALE-108. Phoenix owns item CRUD, history, movement, and maintenance. Svelte consumes these operations through `@dhc/api-client`; the legacy `ItemService` and `HistoryService` have been removed. |
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
| Regenerate full API contract | Run `mise run api-gen` from repo root | Runs `mix gen.controllers` then TS client generator. Fails fast if either step errors. See `docs/agents/commands.md`. |
| Generate controllers from spec | Run `mix gen.controllers` in `apps/phoenix` | Generates controller + JSON renderer + contract test per tag. REST mapping from HTTP method + path. `--force` overwrites all, `--force=<path>` overwrites specific file. |
| Generate TS client | Run `pnpm api-gen` (or `pnpm --filter @dhc/api-client api:generate`) | NEW — from OpenAPI spec via `@hey-api/openapi-ts`. Output: `packages/api-client/src/client/` (gitignored, auto-generated on `pnpm install` via postinstall). |
| Add E2E test | `e2e/` | Use helpers from `setupFunctions.ts` |
| Seed dev data | `apps/phoenix/dev/dev_seeds.ex` + `dev/mix/tasks/seed.*.ex` | Dev-only. `mise run seed-members [count]`, `seed-waitlist [count]`, `seed-committee [csv]`. Uses [fakerer](https://github.com/artkay/fakerer) (`:faker` OTP app, Hex `:fakerer`, dev-only dep). Rows created concurrently via `Task.async_stream`. Inserts go through Ecto schemas (`WaitlistEntry`, `UserProfile`, `MemberProfile`, `Dhc.Auth.UserRole`, `Dhc.Waitlist.WaitlistGuardian`). `auth.users` stays raw SQL (Supabase-owned). |
| Run Phoenix tests | `mise run phx-test` | Testcontainers-elixir starts the `db` profile of the root `docker-compose.yml` per run, migrates, runs tests, tears down. No `supabase start` needed. See ADR 0006. |
| Run structural lint | `mise run ast-lint` | ast-grep rules from `.ast-grep/rules/` (config: `sgconfig.yml`). Currently enforces `created_at` timestamp convention on Ecto migrations. Validate rule fixtures with `mise run ast-test`. The LSP is wired in `opencode.json` for live diagnostics. |
| Configure Sentry | `config/runtime.exs` (prod block) + `config/config.exs` + `lib/dhc/application.ex` | Set `SENTRY_DSN` env var; integrates Phoenix, Oban, Logger, OpenTelemetry tracing (Bandit/Phoenix/Ecto), and Sentry Logs |
| View ADRs | `docs/adr/` | Key architectural decisions |
| View domain glossary | `CONTEXT.md` | Domain language reference |
