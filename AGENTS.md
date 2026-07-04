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
| Add Phoenix Inventory Category slice | `apps/phoenix/lib/dhc/inventory.ex` (context) + `apps/phoenix/lib/dhc/inventory/equipment_category.ex` (schema) + `apps/phoenix/lib/dhc/inventory/json_array.ex` (custom jsonb-array type) + `apps/phoenix/lib/dhc_web/controllers/inventory_categories_controller.ex` + `inventory_categories_json.ex` | NEW — ALE-105. The first Inventory capability slice migrated from the SvelteKit `CategoryService` (Kysely/RLS) to Phoenix. Endpoints `GET/POST /api/inventory/categories` and `GET/PATCH/DELETE /api/inventory/categories/:id` follow the ALE-104 contract. Reads are any authenticated member (`:authenticated_api`); writes use the `:inventory_admin_api` pipeline (`quartermaster`/`president`/`admin`, mirroring Svelte `INVENTORY_ROLES`). Delete returns `409` when `inventory_items` still reference the category (FK is `on_delete: :nothing`, so the guard is explicit, not DB-enforced). `available_attributes` is a jsonb **array** of attribute-definition maps; `Dhc.Inventory.JsonArray` normalizes the legacy `'{}'::jsonb` column default to `[]`. The Svelte categories list/create/edit pages now consume `@dhc/api-client` (`inventoryCategoriesIndex`/`Create`/`Update`/`Delete`) instead of browser Supabase PostgREST. The remaining Inventory slices (containers, items, history) are still Svelte/Kysely-owned. |
| Add Phoenix Inventory Container slice | `apps/phoenix/lib/dhc/inventory.ex` (container context fns, appended after the category slice) + `apps/phoenix/lib/dhc/inventory/container.ex` (Ecto schema) + `apps/phoenix/lib/dhc_web/controllers/inventory_containers_controller.ex` + `inventory_containers_json.ex` | NEW — ALE-106. Second Inventory capability slice migrated from the SvelteKit `ContainerService` (Kysely/RLS) to Phoenix. Endpoints `GET/POST /api/inventory/containers` and `GET/PATCH/DELETE /api/inventory/containers/:id` follow the ALE-104 contract. Reads `:authenticated_api`; writes `:inventory_admin_api`. **`containers.created_by` is NOT NULL** → `Dhc.Inventory.create_container/2` derives it from the caller's Supabase JWT `sub` (`conn.assigns.current_user.sub`); never user-writable. `update_container/2` enforces circular-parent prevention server-side (walks the `parent_container_id` chain; setting the parent to the container itself or a descendant returns `{:error, :circular_parent}` → `422`) — preserves the Svelte UI's descendant filtering as a server invariant since the client hierarchy builder recurses without memoization. `delete_container/1` returns `409` when the container still directly contains items (`inventory_items.container_id` FK is `on_delete: :nothing`); child containers cascade-delete (`containers.parent_container_id` is `on_delete: :delete_all`). Raw-table selects (`inventory_items`/`equipment_categories` have no Ecto schema in this slice) return uuid columns as 16-byte binaries that Jason cannot encode — `list_container_items/1` casts `?::text` inside `json_build_object`. The Svelte containers list/create/detail/edit pages now consume `@dhc/api-client` (`inventoryContainersIndex`/`Show`/`Create`/`Update`/`Delete`); route load fns map camelCase API payloads back to the legacy snake_case shapes the templates consume. Remaining Inventory slices: items (ALE-107), movement/maintenance (ALE-108). |
| Add Phoenix Inventory Item slice | `apps/phoenix/lib/dhc/inventory.ex` (item + history context fns) + `apps/phoenix/lib/dhc/inventory/item.ex` + `apps/phoenix/lib/dhc/inventory/inventory_history.ex` + `apps/phoenix/lib/dhc_web/controllers/inventory_items_controller.ex` + `inventory_items_json.ex` | NEW — ALE-107. Third Inventory slice migrated from SvelteKit `ItemService`/`HistoryService` to Phoenix. Endpoints `GET/POST /api/inventory/items`, `GET/PATCH/DELETE /api/inventory/items/:id`, and `GET /api/inventory/items/:id/history` follow the ALE-104 contract. Reads use `:authenticated_api`; writes use `:inventory_admin_api` (`quartermaster`/`president`/`admin`). `inventory_items.created_by`/`updated_by` derive from the caller's Supabase JWT `sub`, never request bodies. List uses cursor pagination (`limit` + opaque `cursor`) over `(created_at, id)`, not offset/page. `create_item/2` records `created` history; `update_item/3` records `updated`, and also records `moved` before `updated` when `containerId` changes. Delete returns `204`; no delete history row is preserved because `inventory_history.item_id` cascades on delete. Svelte item list/create/detail pages now consume `@dhc/api-client` (`inventoryItemsIndex`/`Show`/`History`/`Create`/`Update`) and map camelCase API payloads back to legacy snake_case template shapes. Remaining Inventory slice: movement/maintenance (ALE-108). |
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
| Run structural lint | `mise run ast-lint` | ast-grep rules from `.ast-grep/rules/` (config: `sgconfig.yml`). Currently enforces `created_at` timestamp convention on Ecto migrations. Validate rule fixtures with `mise run ast-test`. The LSP is wired in `opencode.json` for live diagnostics. |
| Configure Sentry | `config/runtime.exs` (prod block) + `config/config.exs` + `lib/dhc/application.ex` | Set `SENTRY_DSN` env var; integrates Phoenix, Oban, Logger, OpenTelemetry tracing (Bandit/Phoenix/Ecto), and Sentry Logs |
| View ADRs | `docs/adr/` | Key architectural decisions |
| View domain glossary | `CONTEXT.md` | Domain language reference |

## MIGRATION NOTES

See [docs/agents/migration-notes.md](docs/agents/migration-notes.md).

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
