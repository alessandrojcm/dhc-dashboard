# Tech Stack

## Active (SvelteKit + Supabase)

- **Frontend**: SvelteKit 2.x, Svelte 5 (runes), Tailwind CSS, shadcn-svelte
- **Backend**: Supabase (Postgres + Auth + Edge Functions)
- **ORM**: Kysely (mutations), Supabase client (queries)
- **State**: TanStack Query (`createQuery(() => ({}))` thunk pattern)
- **Table**: `@tanstack/table-core` `^8.21.x`, integrated through the custom Svelte 5 adapter in `src/lib/components/ui/data-table/`. The adapter supplies rune-based table state and rendering helpers, and imports shared table types directly from `table-core`; `@tanstack/svelte-table` is not required. Treat adoption of the official Svelte adapter as a deliberate v9 migration rather than adding its v8 package alongside the custom adapter.
- **Payments**: Stripe
- **Validation**: Valibot
- **Forms**: Superforms
- **Deployment**: Cloudflare (adapter-cloudflare + Hyperdrive)
- **Monitoring**: Sentry

## In Progress (Phoenix + Ecto + Oban)

- **Framework**: Phoenix 1.8.7, Bandit 1.11.0
- **Language**: Elixir 1.18.4, Erlang/OTP 27
- **Database**: Ecto 3.13 + Postgrex (shared Postgres with Supabase)
- **Background Jobs**: Oban 2.22.1 (replaces pgmq + pg_cron)
- **Authentication target**: Phoenix 1.8 generated authentication (`mix phx.gen.auth`) with Assent 0.3.1 for Discord OAuth; DHC-owned Postgres principals, identities, tokens, and sessions replace Supabase Auth after the specified cutover
- **API Style**: JSON API via Phoenix controllers, spec-first with OpenAPI
- **Error Tracking**: Sentry 13.0.1 via `sentry` package + `hackney`
- **Realtime (browser)**: official `phoenix` JS client (~1.8.x) for Notification invalidation signals over the WebSocket `/socket`; local to `NotificationCenter` via `notification-realtime.svelte.ts`. Best-effort only; HTTP API remains authoritative. `authToken` is captured at `Socket` construction, so `TOKEN_REFRESHED` rebuilds the socket/channel.

## Tooling & Task Runner

- **Tool version manager**: mise (`.mise.toml` pins Node, Erlang, Elixir, pnpm)
- **Task runner**: mise tasks (replaces Makefile — `mise run <task>`)
- **Package manager**: pnpm (workspaces)
- **API contract generation**: `mise run api-gen` (Phoenix stubs + TS client)

## Experimental Features (SvelteKit)

- **Remote Functions**: `remoteFunctions: true` in svelte.config.js
- **Async Components**: `async: true` compiler option
- Uses `.remote.ts` files for server functions callable from client
