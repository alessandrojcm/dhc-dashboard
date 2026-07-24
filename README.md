# Dublin HEMA Club Dashboard

Monorepo for the club dashboard:

- `apps/web` — SvelteKit frontend (`@dhc/web`), deployed to Cloudflare Workers
- `apps/phoenix` — Phoenix JSON API and Oban workers, deployed to Fly.io
- `packages/api-client` — generated TypeScript client for the Phoenix OpenAPI contract

Install dependencies from the repository root:

```bash
pnpm install
```

Use the root mise tasks for development and verification:

```bash
docker compose up -d db
mise run phx-server
mise run dev
mise run ci
```

Root `pnpm` scripts forward frontend commands to `@dhc/web`, so `pnpm build`,
`pnpm check`, and `pnpm test:unit -- --run` also work from the repository root.
Environment files remain at the repository root; `apps/web/vite.config.ts` loads
that directory through Vite's `envDir` setting.
