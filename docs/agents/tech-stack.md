# Tech Stack

## Active (SvelteKit + Supabase)

- **Frontend**: SvelteKit 2.x, Svelte 5 (runes), Tailwind CSS, shadcn-svelte
- **Backend**: Supabase (Postgres + Auth + Edge Functions)
- **ORM**: Kysely (mutations), Supabase client (queries)
- **State**: TanStack Query (`createQuery(() => ({}))` thunk pattern)
- **Charts**: LayerChart 2.2 on Svelte 5. The shared tooltip adapter reads `getChartContext().tooltip`; `getTooltipContext()` was removed in LayerChart 2.x and must not be reintroduced.
- **Table**: `@tanstack/table-core` `^8.21.x`, integrated through the custom Svelte 5 adapter in `src/lib/components/ui/data-table/`. The adapter supplies rune-based table state and rendering helpers, and imports shared table types directly from `table-core`; `@tanstack/svelte-table` is not required. Treat adoption of the official Svelte adapter as a deliberate v9 migration rather than adding its v8 package alongside the custom adapter.
- **Payments**: Stripe
- **Validation**: Valibot
- **Forms**: Superforms
- **Deployment**: Cloudflare (adapter-cloudflare + Hyperdrive)
- **Monitoring**: Sentry

## In Progress (Phoenix + Ecto + Oban)

- **Framework**: Phoenix 1.8.11, Bandit 1.12.4
- **Language**: Elixir 1.18.4, Erlang/OTP 27
- **Database**: Ecto 3.14 + Postgrex 0.22.4 (shared Postgres with Supabase)
- **Background Jobs**: Oban 2.23 (replaces pgmq + pg_cron)
- **Email transport**: Swoosh 1.27 behind `Dhc.Email.Mailer` (ADR 0021) — `Swoosh.Adapters.Loops` in prod, Mailpit over HTTP in dev, `Swoosh.Adapters.Test` in tests; `gen_smtp` is gone. See [commands.md](commands.md) for the dev workflow.
- **Email templates**: React Email 6 (`react-email` unified package) in `packages/email-templates` (ADR 0022) — one component per Email Kind with metadata exports (`defineTemplate`: subject, sender, UPPER_SNAKE typed variables); Resend constraints (≤20 vars, reserved names like `FIRST_NAME`/`LAST_NAME`/`EMAIL`) are validated at import time. Preview via `pnpm --filter @dhc/email-templates dev`. No render/copy tests — neither React Email nor Resend publishes testing guidance for template assertions.
- **Authentication target**: Phoenix 1.8 generated authentication (`mix phx.gen.auth`) with Assent 0.3.1 for Discord OAuth; DHC-owned Postgres principals, identities, tokens, and sessions replace Supabase Auth after the specified cutover
- **Discord server REST**: Nostrum 0.10.4 behind `Dhc.Discord.Adapter`; the stable release is loaded as an included application and only its ratelimiter is supervised, avoiding a gateway connection in tokenless dev/test environments
- **API Style**: JSON API via Phoenix controllers, spec-first with OpenAPI
- **Error Tracking**: Sentry 13.4 via the `sentry` package and Finch; Hackney is test-only for Testcontainers
- **Realtime (browser)**: official `phoenix` JS client (~1.8.x) for Notification invalidation signals over the WebSocket `/socket`; local to `NotificationCenter` via `notification-realtime.svelte.ts`. Best-effort only; HTTP API remains authoritative. `authToken` is captured at `Socket` construction, so `TOKEN_REFRESHED` rebuilds the socket/channel.

## Tooling & Task Runner

- **Tool version manager**: mise (`.mise.toml` pins Node, Erlang, Elixir, pnpm)
- **Task runner**: mise tasks (replaces Makefile — `mise run <task>`)
- **Package manager**: pnpm (workspaces)
- **API contract generation**: `mise run api-gen` (Phoenix stubs + TS client)
- **Discord migration tooling**: `@discordjs/rest` and `discord-api-types` are root dev dependencies used only by the throwaway roster export script; they are not application runtime dependencies

## Experimental Features (SvelteKit)

- **Remote Functions**: `remoteFunctions: true` in svelte.config.js
- **Async Components**: `async: true` compiler option
- Uses `.remote.ts` files for server functions callable from client
