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

## Namespace Devbox image

`Dockerfile.remote` is a repository-independent Namespace Devbox image. It
contains system build tools, mise with Node, Bun, ast-grep, OpenCode v2, and the
portable prompts/agent configuration/plugins from
[`alessandrojcm/opencode-config`](https://github.com/alessandrojcm/opencode-config).
It deliberately does **not** copy this repository or install its dependencies:
Namespace checks a selected repository out beneath `/workspaces` after creating
the Devbox.

Build it with the repository root as context:

```bash
devbox image build . --name=YOUR_NAMESPACE/DHC_REMOTE --file Dockerfile.remote
```

The image runs as Namespace's `devbox` user (UID `1001`). Provider credentials,
models, MCP servers, and other machine-specific OpenCode settings must be added
at Devbox runtime; the baked configuration has no credentials. OpenCode v2 is
an upstream beta and does not officially support Docker, so this setup uses its
documented npm package pragmatically rather than a supported OpenCode container
distribution.
