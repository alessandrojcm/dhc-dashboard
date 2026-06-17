# Tech Stack

## Active (SvelteKit + Supabase)

- **Frontend**: SvelteKit 2.x, Svelte 5 (runes), Tailwind CSS, shadcn-svelte
- **Backend**: Supabase (Postgres + Auth + Edge Functions)
- **ORM**: Kysely (mutations), Supabase client (queries)
- **State**: TanStack Query (`createQuery(() => ({}))` thunk pattern)
- **Table**: `@tanstack/svelte-table` and `@tanstack/table-core` must stay on the same major version (currently `^8.21.x`). Mismatched versions (e.g. v9 alpha svelte-table with v8 table-core) cause subtle type errors in `FlexRender` and column definitions.
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
- **API Style**: JSON API via Phoenix controllers, spec-first with OpenAPI
- **Error Tracking**: Sentry 13.0.1 via `sentry` package + `hackney`

## Tooling & Task Runner

- **Tool version manager**: mise (`.mise.toml` pins Node, Erlang, Elixir, pnpm)
- **Task runner**: mise tasks (replaces Makefile — `mise run <task>`)
- **Package manager**: pnpm (workspaces)
- **API contract generation**: `mise run api-gen` (Phoenix stubs + TS client)

## Experimental Features (SvelteKit)

- **Remote Functions**: `remoteFunctions: true` in svelte.config.js
- **Async Components**: `async: true` compiler option
- Uses `.remote.ts` files for server functions callable from client
