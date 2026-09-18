# Tech Stack

## Active (SvelteKit + Phoenix API)

- **Frontend**: SvelteKit 2.x, Svelte 5 (runes), Tailwind CSS, shadcn-svelte
- **Backend**: Phoenix JSON API (see below); the SvelteKit app talks to it only through the generated `@dhc/api-client` (`packages/api-client`, generated from `apps/phoenix/priv/api/openapi.yaml`)
- **Types**: every API shape comes from `@dhc/api-client`. The Supabase-generated `apps/web/src/database.types.ts` and the `$database` Vite alias were deleted after the Phoenix migration; do not reintroduce a database-schema type file — add the shape to the OpenAPI contract and regenerate (`mise run api-gen`).
- **State**: TanStack Query (`createQuery(() => ({}))` thunk pattern)
- **Charts**: LayerChart 2.2 on Svelte 5. The shared tooltip adapter reads `getChartContext().tooltip`; `getTooltipContext()` was removed in LayerChart 2.x and must not be reintroduced.
- **Table**: `@tanstack/table-core` `^8.21.x`, integrated through the custom Svelte 5 adapter in `src/lib/components/ui/data-table/`. The adapter supplies rune-based table state and rendering helpers, and imports shared table types directly from `table-core`; `@tanstack/svelte-table` is not required. Treat adoption of the official Svelte adapter as a deliberate v9 migration rather than adding its v8 package alongside the custom adapter.
- **Payments**: Stripe
- **Validation**: Valibot
- **Workflow state machines**: XState v5 (`xstate`, `@xstate/svelte`), used only for Invitation Acceptance (ADR 0024): pure `initialTransition`/`transition` on the server, per-component `useMachine` actors in the browser. Never a module-scope actor.
- **Realtime (browser)**: official `phoenix` JS client (~1.8.x) for Notification invalidation signals over the WebSocket `/socket`; local to `NotificationCenter` via `notification-realtime.svelte.ts`. Best-effort only; HTTP API remains authoritative. `authToken` is captured at `Socket` construction, so `TOKEN_REFRESHED` rebuilds the socket/channel. Web Push (ADR 0025) is a second best-effort channel behind the same notification row.
- **Authentication (browser side)**: the `_dhc_session` cookie issued by Phoenix; `hooks.server.ts` forwards it to `GET /api/auth/session` and exposes the projection as `locals.session`. Frontend authorization is advisory UX policy in `$lib/server/authorization` (GH-510); Phoenix is authoritative.
- **Deployment**: Cloudflare Workers via `@sveltejs/adapter-cloudflare`. The `HYPERDRIVE` binding still declared in `wrangler.jsonc` is a Supabase-era leftover that no application code reads.
- **Monitoring**: Sentry (`@sentry/sveltekit`)

## Backend (Phoenix + Ecto + Oban)

The Supabase → Phoenix migration is complete (root `AGENTS.md`). Supabase Auth, Edge Functions, pgmq/pg_cron, Kysely and the Supabase JS client are gone; Postgres is owned and migrated by Ecto.

- **Framework**: Phoenix 1.8.11, Bandit 1.12.5 (keep ≥ 1.12.5 — CVE-2026-74836 / CVE-2026-75484)
- **Language**: Elixir 1.20, Erlang/OTP 29 (pinned in `.mise.toml`)
- **Database**: Ecto SQL 3.14 + Postgrex 0.22.4
- **Background Jobs**: Oban 2.23
- **Email transport**: Swoosh 1.27 behind `Dhc.Email.Mailer` (ADR 0021) — `Swoosh.Adapters.Resend` in prod, Mailpit over HTTP in dev, `Swoosh.Adapters.Test` in tests; `gen_smtp` is gone. See [commands.md](commands.md) for the dev workflow.
- **Email templates**: React Email 6 (`react-email` unified package) in `packages/email-templates` (ADR 0022) — one component per Email Kind with metadata exports (`defineTemplate`: subject, sender, UPPER_SNAKE typed variables); Resend constraints (≤20 vars, reserved names like `FIRST_NAME`/`LAST_NAME`/`EMAIL`) are validated at import time. Preview via `pnpm --filter @dhc/email-templates dev`. Render-placeholder tests exist in vitest; the sync pipeline itself is exercised only against real Resend from CI.
- **Template sync**: official `resend` SDK (Templates API) + `tsx` runner, driven by `packages/email-templates/scripts/sync.tsx` and the mise tasks `email-sync` / `email-sync-publish` / `email-smoke`; CI wiring in `.github/workflows/email-templates.yml` (drafts on PRs, publish + smoke on main). See [commands.md](commands.md).
- **Authentication**: Phoenix 1.8 generated authentication (`mix phx.gen.auth`) with Assent 0.3.1 for Discord OAuth; DHC-owned Postgres principals, identities, tokens, and sessions (`Dhc.Auth`). Inventory-operator eligibility (active profile + role) lives once in `Dhc.Auth` and is shared by `RequireSession` and loan notifications.
- **Discord server REST**: Nostrum 0.10.4 behind `Dhc.Discord.Adapter`; the stable release is loaded as an included application and only its ratelimiter is supervised, avoiding a gateway connection in tokenless dev/test environments
- **API Style**: JSON API via Phoenix controllers, spec-first with OpenAPI (ADR 0003; `mix gen.controllers` per slice)
- **Error Tracking**: Sentry 13.4 via the `sentry` package and Finch; Hackney is test-only for Testcontainers
- **Web Push**: `web_push_ex` builds RFC 8291/8292 requests, Req sends them behind the `WebPush.Sender` behaviour (ADR 0025)

## Tooling & Task Runner

- **Tool version manager**: mise (`.mise.toml` pins Node, Erlang, Elixir, pnpm)
- **Task runner**: mise tasks (replaces Makefile — `mise run <task>`)
- **Package manager**: pnpm (workspaces)
- **API contract generation**: `mise run api-gen` (Phoenix stubs + TS client)
- **Discord migration tooling**: `@discordjs/rest` and `discord-api-types` are root dev dependencies used only by the throwaway roster export script; they are not application runtime dependencies

## Experimental Features (SvelteKit)

- **Remote Functions**: `remoteFunctions: true` in the SvelteKit config (now inside `apps/web/vite.config.ts`; `svelte.config.js` is gone)
- **Async Components**: `async: true` compiler option
- Uses `.remote.ts` files for server functions callable from client
